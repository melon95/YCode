//! Happy-path smoke: drive the EchoAdapter through a full turn.

use std::time::Duration;

use anyhow::Result;
use tracing::info;
use ycode_echo_adapter::EchoAdapter;

use crate::{assert_done_endturn, boxed, drive_to_terminal, dummy_start, temp_db};

pub async fn run() -> Result<()> {
    let db = temp_db().await?;
    let (start, _keep) = dummy_start("echo", "smoke-echo")?;
    let runner = ycode_core::SessionRunner::start(db, boxed(EchoAdapter::new()), start).await?;

    runner.prompt("hello world".into()).await?;
    let final_state = drive_to_terminal(&runner, Duration::from_secs(5)).await?;
    assert_done_endturn(&final_state)?;

    runner.shutdown().await?;
    info!("smoke echo: PASS");
    Ok(())
}
