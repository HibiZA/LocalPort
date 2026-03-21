mod client;
mod commands;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "devspace",
    about = "Manage parallel development projects",
    version
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Initialize a project in the current directory
    Init {
        /// Project name (defaults to directory name)
        #[arg(short, long)]
        name: Option<String>,
    },
    /// Show status of all projects and routes
    Status,
    /// One-time system setup (DNS resolver, Caddy CA, port forwarding)
    Setup,
    /// Daemon management commands
    Daemon {
        #[command(subcommand)]
        command: DaemonCommands,
    },
}

#[derive(Subcommand)]
enum DaemonCommands {
    /// Start the daemon
    Start {
        /// Run in foreground
        #[arg(long)]
        foreground: bool,
    },
    /// Stop the daemon
    Stop,
    /// Show daemon status
    Status,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Init { name } => commands::init::run(name).await,
        Commands::Status => commands::status::run().await,
        Commands::Setup => commands::setup::run().await,
        Commands::Daemon { command } => match command {
            DaemonCommands::Start { foreground } => {
                commands::status::start_daemon(foreground).await
            }
            DaemonCommands::Stop => commands::status::stop_daemon().await,
            DaemonCommands::Status => commands::status::daemon_status().await,
        },
    }
}
