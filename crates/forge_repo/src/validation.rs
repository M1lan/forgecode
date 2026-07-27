use std::path::Path;
use std::sync::Arc;

use anyhow::{Context, Result};
use async_trait::async_trait;
use forge_app::{EnvironmentInfra, GrpcInfra};
use forge_config::ForgeConfig;
use forge_domain::{SyntaxError, ValidationRepository};
use tracing::{debug, warn};

use crate::proto_generated::forge_service_client::ForgeServiceClient;
use crate::proto_generated::{self, File, ValidateFilesRequest};

/// gRPC implementation of ValidationRepository
pub struct ForgeValidationRepository<I> {
    infra: Arc<I>,
}

impl<I> ForgeValidationRepository<I> {
    /// Create a new repository with the given infrastructure
    ///
    /// # Arguments
    /// * `infra` - Infrastructure that provides gRPC connection
    pub fn new(infra: Arc<I>) -> Self {
        Self { infra }
    }
}

#[async_trait]
impl<I: GrpcInfra + EnvironmentInfra<Config = ForgeConfig>> ValidationRepository
    for ForgeValidationRepository<I>
{
    async fn validate_file(
        &self,
        path: impl AsRef<Path> + Send,
        content: &str,
    ) -> Result<Vec<SyntaxError>> {
        if !self.infra.get_config()?.enable_remote_file_validation {
            debug!("Remote file validation disabled");
            return Ok(Vec::new());
        }

        let path = path.as_ref();
        let path_str = path.to_string_lossy().to_string();

        debug!(path = %path_str, "Starting syntax validation");

        // Create validation request for single file
        let proto_file = File { path: path_str.clone(), content: content.to_string() };
        let request = tonic::Request::new(ValidateFilesRequest { files: vec![proto_file] });

        // Call gRPC API
        let channel = self.infra.channel()?;
        let mut client = ForgeServiceClient::new(channel);
        let response = client
            .validate_files(request)
            .await
            .context("Failed to call ValidateFiles gRPC")?
            .into_inner();

        // Extract validation result for our file
        let result = response
            .results
            .into_iter()
            .find(|r| r.file_path == path_str)
            .context("Validation response missing file result")?;

        // Convert proto status to error message
        match result.status {
            Some(proto_generated::ValidationStatus { status: Some(status) }) => match status {
                proto_generated::validation_status::Status::Valid(_) => {
                    debug!(path = %path_str, "Syntax validation passed");
                    Ok(vec![])
                }
                proto_generated::validation_status::Status::Errors(error_list) => {
                    if error_list.errors.is_empty() {
                        return Ok(vec![]);
                    }

                    let ext = path
                        .extension()
                        .and_then(|e| e.to_str())
                        .unwrap_or("unknown");

                    let error_count = error_list.errors.len();

                    // Log and convert proto errors to domain errors
                    let errors = error_list
                        .errors
                        .into_iter()
                        .map(|error| {
                            warn!(
                                path = %path_str,
                                extension = ext,
                                error_count,
                                error_line = error.line,
                                error_column = error.column,
                                error_message = %error.message,
                                "Syntax validation failed"
                            );
                            SyntaxError {
                                line: error.line,
                                column: error.column,
                                message: error.message,
                            }
                        })
                        .collect();

                    Ok(errors)
                }
                proto_generated::validation_status::Status::UnsupportedLanguage(_) => {
                    let ext = path
                        .extension()
                        .and_then(|e| e.to_str())
                        .unwrap_or("unknown");
                    debug!(
                        path = %path_str,
                        extension = ext,
                        "Syntax validation skipped: unsupported language"
                    );
                    Ok(vec![])
                }
            },
            _ => Ok(vec![]),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use fake::{Fake, Faker};
    use forge_app::EnvironmentInfra;
    use forge_config::{ConfigReader, ForgeConfig};
    use pretty_assertions::assert_eq;

    use super::*;

    struct MockInfra {
        config: ForgeConfig,
        channel_calls: AtomicUsize,
    }

    impl MockInfra {
        fn new(enable_remote_file_validation: bool) -> Self {
            let config = ConfigReader::default()
                .read_toml(&format!(
                    "enable_remote_file_validation = {enable_remote_file_validation}"
                ))
                .build()
                .unwrap();
            Self { config, channel_calls: AtomicUsize::new(0) }
        }
    }

    impl EnvironmentInfra for MockInfra {
        type Config = ForgeConfig;

        fn get_env_var(&self, _key: &str) -> Option<String> {
            None
        }

        fn get_env_vars(&self) -> BTreeMap<String, String> {
            BTreeMap::new()
        }

        fn get_environment(&self) -> forge_domain::Environment {
            Faker.fake()
        }

        fn get_config(&self) -> anyhow::Result<Self::Config> {
            Ok(self.config.clone())
        }

        async fn update_environment(
            &self,
            _ops: Vec<forge_domain::ConfigOperation>,
        ) -> anyhow::Result<()> {
            Ok(())
        }
    }

    impl GrpcInfra for MockInfra {
        fn channel(&self) -> anyhow::Result<tonic::transport::Channel> {
            self.channel_calls.fetch_add(1, Ordering::SeqCst);
            Err(anyhow::anyhow!("remote validation channel requested"))
        }

        fn hydrate(&self) {}
    }

    #[tokio::test]
    async fn test_remote_file_validation_is_disabled_by_default() {
        let fixture = Arc::new(MockInfra::new(false));
        let repository = ForgeValidationRepository::new(fixture.clone());

        let actual = repository
            .validate_file("/workspace/test.rs", "fn main() {}")
            .await;

        let expected = Vec::<SyntaxError>::new();
        assert_eq!(actual.unwrap(), expected);
        assert_eq!(fixture.channel_calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn test_remote_file_validation_requires_explicit_opt_in() {
        let fixture = Arc::new(MockInfra::new(true));
        let repository = ForgeValidationRepository::new(fixture.clone());

        let actual = repository
            .validate_file("/workspace/test.rs", "fn main() {}")
            .await
            .unwrap_err();

        let expected = "remote validation channel requested";
        assert_eq!(actual.to_string(), expected);
        assert_eq!(fixture.channel_calls.load(Ordering::SeqCst), 1);
    }
}
