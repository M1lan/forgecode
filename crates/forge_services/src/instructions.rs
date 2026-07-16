use std::path::PathBuf;
use std::sync::Arc;

use forge_app::{CommandInfra, CustomInstructionsService, EnvironmentInfra, FileReaderInfra};

/// This service looks for custom instruction files in the following locations,
/// in order of priority (earlier sources render first):
/// 1. Base path (environment.base_path)
/// 2. Git root directory (if available)
/// 3. Current working directory (environment.cwd)
/// 4. The file named by the `FORGE_EXTRA_INSTRUCTIONS_PATH` environment
///    variable, if set and non-empty. This session-specific source has the
///    lowest priority and is rendered after the cwd source. "Rendered after" is
///    prompt ordering only; it is not a deterministic override of
///    `agent.custom_rules`.
#[derive(Clone)]
pub struct ForgeCustomInstructionsService<F> {
    infra: Arc<F>,
    cache: tokio::sync::OnceCell<Vec<String>>,
}

/// Environment variable naming a file whose contents are injected as
/// session-specific extra instructions (lowest priority, rendered last).
const EXTRA_INSTRUCTIONS_ENV: &str = "FORGE_EXTRA_INSTRUCTIONS_PATH";

/// Maximum number of bytes read from the `FORGE_EXTRA_INSTRUCTIONS_PATH` file;
/// contents larger than this are truncated (on a UTF-8 char boundary).
const MAX_EXTRA_INSTR_BYTES: usize = 32 * 1024;

impl<F: EnvironmentInfra + FileReaderInfra + CommandInfra> ForgeCustomInstructionsService<F> {
    pub fn new(infra: Arc<F>) -> Self {
        Self { infra, cache: Default::default() }
    }

    async fn discover_agents_files(&self) -> Vec<PathBuf> {
        let mut paths = Vec::new();
        let environment = self.infra.get_environment();

        // Base custom instructions
        let base_agent_md = environment.global_agentsmd_path();
        if !paths.contains(&base_agent_md) {
            paths.push(base_agent_md);
        }

        // Repo custom instructions
        if let Some(git_root_path) = self.get_git_root().await {
            let git_agent_md = git_root_path.join("AGENTS.md");
            if !paths.contains(&git_agent_md) {
                paths.push(git_agent_md);
            }
        }

        // Working dir custom instructions
        let cwd_agent_md = environment.local_agentsmd_path();
        if !paths.contains(&cwd_agent_md) {
            paths.push(cwd_agent_md);
        }

        // Session-specific extra instructions (lowest priority, rendered last).
        // A set-but-empty variable is treated as unset.
        if let Some(extra_path) = self
            .infra
            .get_env_var(EXTRA_INSTRUCTIONS_ENV)
            .filter(|value| !value.is_empty())
        {
            paths.push(PathBuf::from(extra_path));
        }

        paths
    }

    async fn get_git_root(&self) -> Option<PathBuf> {
        let output = self
            .infra
            .execute_command(
                "git rev-parse --show-toplevel".to_owned(),
                self.infra.get_environment().cwd,
                true, // silent mode - don't print git output
                None, // no environment variables needed for git command
            )
            .await
            .ok()?;

        if output.success() {
            Some(PathBuf::from(output.stdout.trim()))
        } else {
            None
        }
    }

    async fn init(&self) -> Vec<String> {
        let paths = self.discover_agents_files().await;

        // Path sourced from FORGE_EXTRA_INSTRUCTIONS_PATH, if any. Used to apply a
        // size cap and path-only observability to that source specifically,
        // without changing behavior of the base/git/cwd sources.
        let extra_path = self
            .infra
            .get_env_var(EXTRA_INSTRUCTIONS_ENV)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from);

        let mut custom_instructions = Vec::new();

        for path in paths {
            let is_extra = Some(&path) == extra_path.as_ref();
            match self.infra.read_utf8(&path).await {
                Ok(mut content) => {
                    if is_extra {
                        // Never log file contents, only the path.
                        tracing::debug!(
                            path = %path.display(),
                            "injecting FORGE_EXTRA_INSTRUCTIONS_PATH into system prompt"
                        );
                        if content.len() > MAX_EXTRA_INSTR_BYTES {
                            tracing::warn!(
                                path = %path.display(),
                                len = content.len(),
                                cap = MAX_EXTRA_INSTR_BYTES,
                                "FORGE_EXTRA_INSTRUCTIONS_PATH exceeds size cap; truncating"
                            );
                            let mut cap = MAX_EXTRA_INSTR_BYTES;
                            while !content.is_char_boundary(cap) {
                                cap -= 1;
                            }
                            content.truncate(cap);
                        }
                    }
                    custom_instructions.push(content);
                }
                Err(error) => {
                    if is_extra {
                        tracing::debug!(
                            path = %path.display(),
                            %error,
                            "FORGE_EXTRA_INSTRUCTIONS_PATH unreadable; skipping"
                        );
                    }
                }
            }
        }

        custom_instructions
    }
}

#[async_trait::async_trait]
impl<F: EnvironmentInfra + FileReaderInfra + CommandInfra> CustomInstructionsService
    for ForgeCustomInstructionsService<F>
{
    async fn get_custom_instructions(&self) -> Vec<String> {
        self.cache.get_or_init(|| self.init()).await.clone()
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::path::Path;

    use forge_app::domain::Environment;
    use forge_domain::{ConfigOperation, FileInfo};
    use pretty_assertions::assert_eq;

    use super::*;

    /// Test infrastructure implementing the three traits the service depends
    /// on.
    #[derive(Clone, Default)]
    struct MockInfra {
        base_path: PathBuf,
        cwd: PathBuf,
        extra_env: Option<String>,
        files: HashMap<PathBuf, String>,
    }

    impl MockInfra {
        fn new() -> Self {
            Self {
                base_path: PathBuf::from("/base"),
                cwd: PathBuf::from("/cwd"),
                extra_env: None,
                files: HashMap::new(),
            }
        }

        fn extra_env(mut self, value: impl Into<String>) -> Self {
            self.extra_env = Some(value.into());
            self
        }

        fn file(mut self, path: impl Into<PathBuf>, content: impl Into<String>) -> Self {
            self.files.insert(path.into(), content.into());
            self
        }
    }

    impl EnvironmentInfra for MockInfra {
        type Config = forge_config::ForgeConfig;

        fn get_environment(&self) -> Environment {
            use fake::{Fake, Faker};
            let mut env: Environment = Faker.fake();
            env.base_path = self.base_path.clone();
            env.cwd = self.cwd.clone();
            env
        }

        fn get_config(&self) -> anyhow::Result<forge_config::ForgeConfig> {
            Ok(forge_config::ForgeConfig::default())
        }

        async fn update_environment(&self, _ops: Vec<ConfigOperation>) -> anyhow::Result<()> {
            unimplemented!()
        }

        fn get_env_var(&self, key: &str) -> Option<String> {
            if key == EXTRA_INSTRUCTIONS_ENV {
                self.extra_env.clone()
            } else {
                None
            }
        }

        fn get_env_vars(&self) -> std::collections::BTreeMap<String, String> {
            std::collections::BTreeMap::new()
        }
    }

    #[async_trait::async_trait]
    impl FileReaderInfra for MockInfra {
        async fn read_utf8(&self, path: &Path) -> anyhow::Result<String> {
            self.files
                .get(path)
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("File not found: {path:?}"))
        }

        fn read_batch_utf8(
            &self,
            _batch_size: usize,
            _paths: Vec<PathBuf>,
        ) -> impl futures::Stream<Item = (PathBuf, anyhow::Result<String>)> + Send {
            futures::stream::empty()
        }

        async fn read(&self, _path: &Path) -> anyhow::Result<Vec<u8>> {
            unimplemented!()
        }

        async fn range_read_utf8(
            &self,
            _path: &Path,
            _start_line: u64,
            _end_line: u64,
        ) -> anyhow::Result<(String, FileInfo)> {
            unimplemented!()
        }
    }

    #[async_trait::async_trait]
    impl CommandInfra for MockInfra {
        async fn execute_command(
            &self,
            _command: String,
            _working_dir: PathBuf,
            _silent: bool,
            _env_vars: Option<Vec<String>>,
        ) -> anyhow::Result<forge_domain::CommandOutput> {
            // Force get_git_root() to return None: an Err is required (a
            // successful CommandOutput with exit_code Some(1) still counts as
            // success via CommandOutput::success()).
            Err(anyhow::anyhow!("no git root"))
        }

        async fn execute_command_raw(
            &self,
            _command: &str,
            _working_dir: PathBuf,
            _env_vars: Option<Vec<String>>,
        ) -> anyhow::Result<std::process::ExitStatus> {
            unimplemented!()
        }
    }

    #[tokio::test]
    async fn test_discover_agents_files_env_unset() {
        let fixture = ForgeCustomInstructionsService::new(Arc::new(MockInfra::new()));

        let actual = fixture.discover_agents_files().await;

        let expected = vec![
            PathBuf::from("/base/AGENTS.md"),
            PathBuf::from("/cwd/AGENTS.md"),
        ];
        assert_eq!(actual, expected);
    }

    #[tokio::test]
    async fn test_discover_agents_files_env_set_appends_last() {
        let fixture = ForgeCustomInstructionsService::new(Arc::new(
            MockInfra::new().extra_env("/tmp/extra.md"),
        ));

        let actual = fixture.discover_agents_files().await;

        let expected = vec![
            PathBuf::from("/base/AGENTS.md"),
            PathBuf::from("/cwd/AGENTS.md"),
            PathBuf::from("/tmp/extra.md"),
        ];
        assert_eq!(actual, expected);
    }

    #[tokio::test]
    async fn test_discover_agents_files_env_empty_treated_as_unset() {
        let fixture = ForgeCustomInstructionsService::new(Arc::new(MockInfra::new().extra_env("")));

        let actual = fixture.discover_agents_files().await;

        let expected = vec![
            PathBuf::from("/base/AGENTS.md"),
            PathBuf::from("/cwd/AGENTS.md"),
        ];
        assert_eq!(actual, expected);
    }

    #[tokio::test]
    async fn test_init_env_set_readable_injects_content() {
        let fixture = ForgeCustomInstructionsService::new(Arc::new(
            MockInfra::new()
                .file("/base/AGENTS.md", "base rules")
                .file("/cwd/AGENTS.md", "cwd rules")
                .extra_env("/tmp/extra.md")
                .file("/tmp/extra.md", "extra rules"),
        ));

        let actual = fixture.init().await;

        let expected = vec![
            "base rules".to_string(),
            "cwd rules".to_string(),
            "extra rules".to_string(),
        ];
        assert_eq!(actual, expected);
    }

    #[tokio::test]
    async fn test_init_env_set_unreadable_silently_absent() {
        // Extra path is configured but has no file entry -> read_utf8 Err.
        let fixture = ForgeCustomInstructionsService::new(Arc::new(
            MockInfra::new()
                .file("/base/AGENTS.md", "base rules")
                .extra_env("/tmp/missing.md"),
        ));

        let actual = fixture.init().await;

        let expected = vec!["base rules".to_string()];
        assert_eq!(actual, expected);
    }

    #[tokio::test]
    async fn test_init_env_oversized_truncated_to_cap() {
        let oversized = "a".repeat(MAX_EXTRA_INSTR_BYTES + 100);
        let fixture = ForgeCustomInstructionsService::new(Arc::new(
            MockInfra::new()
                .extra_env("/tmp/big.md")
                .file("/tmp/big.md", oversized),
        ));

        let actual = fixture.init().await;

        let expected = vec!["a".repeat(MAX_EXTRA_INSTR_BYTES)];
        assert_eq!(actual, expected);
    }
}
