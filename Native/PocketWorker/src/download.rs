//! The upstream loader calls this hook for all assets. Network support is
//! intentionally absent; installation and integrity checking belong to Salient.
use anyhow::{Result, ensure};
use std::path::PathBuf;

pub fn download_if_necessary(source: &str) -> Result<PathBuf> {
    let path = PathBuf::from(source);
    ensure!(path.is_absolute() && path.is_file(), "A local asset is missing");
    Ok(path)
}
