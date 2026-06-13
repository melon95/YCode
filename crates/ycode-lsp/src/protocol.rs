//! Minimal LSP JSON-RPC 2.0 framing.
//!
//! `Content-Length: N\r\n\r\n<json>` over stdio. We deliberately do *not*
//! model the full LSP message zoo as Rust types — params are `serde_json::Value`
//! everywhere, and the handful of methods we drive are constructed inline via
//! `json!`. Less surface area, fewer breakages when LSP types churn.

use std::io;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};

/// JSON-RPC request id. LSP allows either, but we always send numbers — the
/// `String` arm is here to deserialize server-initiated requests faithfully
/// (we don't service them today, but parsing one shouldn't crash the reader).
#[derive(Clone, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RequestId {
    Number(i64),
    String(String),
}

#[derive(Clone, Debug, Deserialize)]
pub struct ResponseError {
    pub code: i64,
    pub message: String,
    #[serde(default)]
    pub data: Option<Value>,
}

/// Catch-all for any wire message. Fields not present on this kind of message
/// stay `None`; the reader inspects the populated combination to classify it
/// (request / response / notification).
#[derive(Debug, Deserialize)]
pub struct IncomingMessage {
    #[serde(default)]
    pub id: Option<RequestId>,
    #[serde(default)]
    pub method: Option<String>,
    #[serde(default)]
    pub params: Option<Value>,
    #[serde(default)]
    pub result: Option<Value>,
    #[serde(default)]
    pub error: Option<ResponseError>,
}

/// Read one LSP message body from `r`. Returns `Ok(None)` on a clean EOF
/// (the server exited). Header keys other than `Content-Length` are ignored.
pub async fn read_message<R: AsyncRead + Unpin>(
    r: &mut BufReader<R>,
) -> io::Result<Option<Vec<u8>>> {
    let mut content_length: Option<usize> = None;
    let mut line = String::new();
    loop {
        line.clear();
        let n = r.read_line(&mut line).await?;
        if n == 0 {
            // EOF before any header — clean shutdown.
            return Ok(None);
        }
        let trimmed = line.trim_end_matches(['\r', '\n']);
        if trimmed.is_empty() {
            break;
        }
        if let Some(value) = trimmed.strip_prefix("Content-Length:") {
            let parsed = value
                .trim()
                .parse::<usize>()
                .map_err(|e| io::Error::other(format!("bad Content-Length: {e}")))?;
            content_length = Some(parsed);
        }
        // Content-Type and other headers are ignored — LSP only ever uses
        // utf-8 JSON in practice.
    }
    let len = content_length
        .ok_or_else(|| io::Error::other("LSP message missing Content-Length header"))?;
    let mut body = vec![0u8; len];
    r.read_exact(&mut body).await?;
    Ok(Some(body))
}

/// Frame `body` with a `Content-Length` header and write it to `w`. Caller is
/// expected to have already JSON-encoded the message.
pub async fn write_message<W: AsyncWrite + Unpin>(w: &mut W, body: &[u8]) -> io::Result<()> {
    let header = format!("Content-Length: {}\r\n\r\n", body.len());
    w.write_all(header.as_bytes()).await?;
    w.write_all(body).await?;
    w.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncSeekExt;

    #[tokio::test]
    async fn roundtrip_one_message() {
        let payload = br#"{"jsonrpc":"2.0","method":"initialized","params":{}}"#;

        let mut buf = std::io::Cursor::new(Vec::<u8>::new());
        write_message(&mut buf, payload).await.unwrap();

        buf.seek(std::io::SeekFrom::Start(0)).await.unwrap();
        let mut reader = BufReader::new(buf);
        let body = read_message(&mut reader).await.unwrap().unwrap();
        assert_eq!(body, payload);
    }

    #[tokio::test]
    async fn eof_yields_none() {
        let buf = std::io::Cursor::new(Vec::<u8>::new());
        let mut reader = BufReader::new(buf);
        assert!(read_message(&mut reader).await.unwrap().is_none());
    }
}
