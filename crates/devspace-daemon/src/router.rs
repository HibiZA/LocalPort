use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::Notify;

#[derive(Debug)]
pub struct Router {
    routes: HashMap<String, SocketAddr>,
    change_notify: Arc<Notify>,
}

impl Router {
    pub fn new(change_notify: Arc<Notify>) -> Self {
        Self {
            routes: HashMap::new(),
            change_notify,
        }
    }

    pub fn add_route(&mut self, hostname: String, addr: SocketAddr) {
        tracing::info!("route added: {} -> {}", hostname, addr);
        self.routes.insert(hostname, addr);
        self.change_notify.notify_one();
    }

    pub fn remove_route(&mut self, hostname: &str) -> bool {
        let removed = self.routes.remove(hostname).is_some();
        if removed {
            tracing::info!("route removed: {}", hostname);
            self.change_notify.notify_one();
        }
        removed
    }

    pub fn list_routes(&self) -> Vec<(String, SocketAddr)> {
        self.routes.iter().map(|(k, v)| (k.clone(), *v)).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_router() -> (Router, Arc<Notify>) {
        let notify = Arc::new(Notify::new());
        let router = Router::new(notify.clone());
        (router, notify)
    }

    #[test]
    fn test_add_and_list() {
        let (mut router, _notify) = test_router();
        let addr: SocketAddr = "127.0.0.1:3000".parse().unwrap();
        router.add_route("myapp.test".to_string(), addr);

        let routes = router.list_routes();
        assert_eq!(routes.len(), 1);
        assert_eq!(routes[0].0, "myapp.test");
        assert_eq!(routes[0].1, addr);
    }

    #[test]
    fn test_remove_route() {
        let (mut router, _notify) = test_router();
        let addr: SocketAddr = "127.0.0.1:3000".parse().unwrap();
        router.add_route("myapp.test".to_string(), addr);

        assert!(router.remove_route("myapp.test"));
        assert!(router.list_routes().is_empty());
        assert!(!router.remove_route("nonexistent.test"));
    }

    #[test]
    fn test_list_routes() {
        let (mut router, _notify) = test_router();
        let addr1: SocketAddr = "127.0.0.1:3000".parse().unwrap();
        let addr2: SocketAddr = "127.0.0.1:5173".parse().unwrap();
        router.add_route("app1.test".to_string(), addr1);
        router.add_route("app2.test".to_string(), addr2);

        let routes = router.list_routes();
        assert_eq!(routes.len(), 2);
    }

    #[tokio::test]
    async fn test_notify_fires_on_add() {
        let notify = Arc::new(Notify::new());
        let mut router = Router::new(notify.clone());
        let addr: SocketAddr = "127.0.0.1:3000".parse().unwrap();

        // Spawn a task that waits for notification
        let notify_clone = notify.clone();
        let handle = tokio::spawn(async move {
            notify_clone.notified().await;
            true
        });

        // Small delay to ensure the task is waiting
        tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;

        router.add_route("myapp.test".to_string(), addr);

        let notified = tokio::time::timeout(tokio::time::Duration::from_millis(100), handle).await;

        assert!(notified.is_ok());
    }
}
