use std::collections::HashMap;
use std::net::SocketAddr;

#[derive(Debug)]
pub struct Router {
    routes: HashMap<String, SocketAddr>,
}

impl Router {
    pub fn new() -> Self {
        Self {
            routes: HashMap::new(),
        }
    }

    /// Resolve a Host header value to an upstream address.
    pub fn resolve(&self, host: &str) -> Option<SocketAddr> {
        // Strip port from host header if present (e.g. "my-app.localhost:8080" -> "my-app.localhost")
        let hostname = host.split(':').next().unwrap_or(host);
        self.routes.get(hostname).copied()
    }

    pub fn add_route(&mut self, hostname: String, addr: SocketAddr) {
        tracing::info!("route added: {} -> {}", hostname, addr);
        self.routes.insert(hostname, addr);
    }

    pub fn remove_route(&mut self, hostname: &str) -> bool {
        let removed = self.routes.remove(hostname).is_some();
        if removed {
            tracing::info!("route removed: {}", hostname);
        }
        removed
    }

    pub fn list_routes(&self) -> Vec<(String, SocketAddr)> {
        self.routes
            .iter()
            .map(|(k, v)| (k.clone(), *v))
            .collect()
    }
}
