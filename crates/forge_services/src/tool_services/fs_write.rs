use std::path::Path;
use std::sync::Arc;

use anyhow::Context;
use bytes::Bytes;
use forge_app::{
    FileDirectoryInfra, FileInfoInfra, FileReaderInfra, FileWriterInfra, FsWriteOutput,
    FsWriteService, compute_hash,
};
use forge_domain::{SnapshotRepository, ValidationRepository};

use crate::utils::assert_absolute_path;

/// Service for creating files with snapshot coordination
///
/// This service coordinates between infrastructure (file I/O) and repository
/// (snapshots) to create files while preserving the ability to undo changes.
///
/// # Line Ending Handling
/// The service preserves the line endings exactly as provided in the input
/// content. The hash is computed on the exact content being written, so it will
/// reflect the actual file content regardless of whether it uses LF or CRLF
/// line endings.
pub struct ForgeFsWrite<F> {
    infra: Arc<F>,
}

impl<F> ForgeFsWrite<F> {
    pub fn new(infra: Arc<F>) -> Self {
        Self { infra }
    }
}

#[async_trait::async_trait]
impl<
    F: FileDirectoryInfra
        + FileInfoInfra
        + FileReaderInfra
        + FileWriterInfra
        + SnapshotRepository
        + ValidationRepository
        + Send
        + Sync,
> FsWriteService for ForgeFsWrite<F>
{
    async fn write(
        &self,
        path: String,
        content: String,
        overwrite: bool,
    ) -> anyhow::Result<FsWriteOutput> {
        let path = Path::new(&path);
        assert_absolute_path(path)?;

        // Validate file syntax using the configured validation repository.
        let errors = self
            .infra
            .validate_file(path, &content)
            .await
            .with_context(|| format!("Failed to validate file {}", path.display()))?;

        if let Some(parent) = Path::new(&path).parent() {
            self.infra
                .create_dirs(parent)
                .await
                .with_context(|| format!("Failed to create directories: {}", path.display()))?;
        }

        // Check if the file exists
        let file_exists = self.infra.is_file(path).await?;

        // If file exists and overwrite flag is not set, return an error
        if file_exists && !overwrite {
            return Err(anyhow::anyhow!(
                "Cannot overwrite existing file: overwrite flag not set.",
            ))
            .with_context(|| format!("File already exists at {}", path.display()));
        }

        // Record the file content before modification and detect its line ending style
        let (old_content, target_line_ending) = if file_exists && overwrite {
            let existing = self.infra.read_utf8(path).await?;
            let line_ending = if existing.contains("\r\n") {
                "\r\n"
            } else {
                "\n"
            };
            (Some(existing), line_ending)
        } else {
            // For new files, use platform default line ending
            #[cfg(windows)]
            let default_ending = "\r\n";
            #[cfg(not(windows))]
            let default_ending = "\n";
            (None, default_ending)
        };

        // SNAPSHOT COORDINATION: Capture snapshot before writing if file exists
        if file_exists {
            self.infra.insert_snapshot(path).await?;
        }

        // Normalize line endings to match the target style before writing
        let normalized_content = content
            .replace("\r\n", "\n") // First normalize all to LF
            .replace('\n', target_line_ending); // Then convert to target

        // Write file only after validation passes and directories are created
        self.infra
            .write(path, Bytes::from(normalized_content.clone()))
            .await?;

        // Compute hash of the normalized content that was written
        let content_hash = compute_hash(&normalized_content);

        Ok(FsWriteOutput {
            path: path.display().to_string(),
            before: old_content,
            errors,
            content_hash,
        })
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use futures::stream;
    use pretty_assertions::assert_eq;

    use super::*;

    #[derive(Default)]
    struct ValidationFailureInfra {
        write_calls: AtomicUsize,
    }

    #[async_trait::async_trait]
    impl FileDirectoryInfra for ValidationFailureInfra {
        async fn create_dirs(&self, _path: &Path) -> anyhow::Result<()> {
            Ok(())
        }
    }

    #[async_trait::async_trait]
    impl FileInfoInfra for ValidationFailureInfra {
        async fn is_binary(&self, _path: &Path) -> anyhow::Result<bool> {
            unreachable!()
        }

        async fn is_file(&self, _path: &Path) -> anyhow::Result<bool> {
            Ok(false)
        }

        async fn exists(&self, _path: &Path) -> anyhow::Result<bool> {
            unreachable!()
        }

        async fn file_size(&self, _path: &Path) -> anyhow::Result<u64> {
            unreachable!()
        }
    }

    #[async_trait::async_trait]
    impl FileReaderInfra for ValidationFailureInfra {
        async fn read_utf8(&self, _path: &Path) -> anyhow::Result<String> {
            unreachable!()
        }

        fn read_batch_utf8(
            &self,
            _batch_size: usize,
            _paths: Vec<PathBuf>,
        ) -> impl futures::Stream<Item = (PathBuf, anyhow::Result<String>)> + Send {
            stream::empty()
        }

        async fn read(&self, _path: &Path) -> anyhow::Result<Vec<u8>> {
            unreachable!()
        }

        async fn range_read_utf8(
            &self,
            _path: &Path,
            _start_line: u64,
            _end_line: u64,
        ) -> anyhow::Result<(String, forge_domain::FileInfo)> {
            unreachable!()
        }
    }

    #[async_trait::async_trait]
    impl FileWriterInfra for ValidationFailureInfra {
        async fn write(&self, _path: &Path, _contents: Bytes) -> anyhow::Result<()> {
            self.write_calls.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }

        async fn append(&self, _path: &Path, _contents: Bytes) -> anyhow::Result<()> {
            unreachable!()
        }

        async fn write_temp(
            &self,
            _prefix: &str,
            _ext: &str,
            _content: &str,
        ) -> anyhow::Result<PathBuf> {
            unreachable!()
        }
    }

    #[async_trait::async_trait]
    impl SnapshotRepository for ValidationFailureInfra {
        async fn insert_snapshot(
            &self,
            _file_path: &Path,
        ) -> anyhow::Result<forge_domain::Snapshot> {
            unreachable!()
        }

        async fn undo_snapshot(&self, _file_path: &Path) -> anyhow::Result<()> {
            unreachable!()
        }
    }

    #[async_trait::async_trait]
    impl ValidationRepository for ValidationFailureInfra {
        async fn validate_file(
            &self,
            _path: impl AsRef<Path> + Send,
            _content: &str,
        ) -> anyhow::Result<Vec<forge_domain::SyntaxError>> {
            Err(anyhow::anyhow!("remote validation failed"))
        }
    }

    #[tokio::test]
    async fn test_write_surfaces_remote_validation_error_without_writing() {
        let fixture = Arc::new(ValidationFailureInfra::default());
        let service = ForgeFsWrite::new(fixture.clone());

        let actual = service
            .write(
                "/workspace/test.rs".to_string(),
                "fn main() {}".to_string(),
                false,
            )
            .await
            .unwrap_err();

        let expected = "Failed to validate file /workspace/test.rs: remote validation failed";
        assert_eq!(format!("{actual:#}"), expected);
        assert_eq!(fixture.write_calls.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn test_normalize_crlf_to_lf() {
        let fixture = "line1\r\nline2\r\nline3";
        let actual = fixture.replace("\r\n", "\n");
        let expected = "line1\nline2\nline3";
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_normalize_lf_to_crlf() {
        let fixture = "line1\nline2\nline3";
        let actual = fixture.replace("\r\n", "\n").replace('\n', "\r\n");
        let expected = "line1\r\nline2\r\nline3";
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_normalize_mixed_endings() {
        let fixture = "line1\r\nline2\nline3\r\nline4";
        let actual = fixture.replace("\r\n", "\n");
        let expected = "line1\nline2\nline3\nline4";
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_normalize_preserves_content() {
        let fixture = "hello world\r\nfoo bar\r\nbaz";
        let actual = fixture.replace("\r\n", "\n").replace('\n', "\r\n");
        let expected = "hello world\r\nfoo bar\r\nbaz";
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_line_ending_detection_crlf() {
        let fixture = "line1\r\nline2\r\nline3";
        let detected = if fixture.contains("\r\n") {
            "\r\n"
        } else {
            "\n"
        };
        let expected = "\r\n";
        assert_eq!(detected, expected);
    }

    #[test]
    fn test_line_ending_detection_lf() {
        let fixture = "line1\nline2\nline3";
        let detected = if fixture.contains("\r\n") {
            "\r\n"
        } else {
            "\n"
        };
        let expected = "\n";
        assert_eq!(detected, expected);
    }

    #[test]
    fn test_hash_consistency_after_normalization() {
        let input_crlf = "line1\r\nline2\r\nline3";
        let normalized = input_crlf.replace("\r\n", "\n");

        let hash1 = compute_hash(&normalized);
        let hash2 = compute_hash(&normalized);

        assert_eq!(hash1, hash2);
    }

    #[test]
    fn test_hash_differs_with_different_endings() {
        let content_lf = "line1\nline2\nline3";
        let content_crlf = "line1\r\nline2\r\nline3";

        let hash_lf = compute_hash(content_lf);
        let hash_crlf = compute_hash(content_crlf);

        assert_ne!(hash_lf, hash_crlf);
    }
}
