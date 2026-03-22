use anyhow::Result;
use tokio::net::UdpSocket;
use tokio::sync::watch;

/// Minimal DNS responder that answers all A queries with 127.0.0.1.
/// Used with /etc/resolver/<tld> to resolve *.test (or other custom TLD) locally.
pub struct DnsResponder {
    port: u16,
}

impl DnsResponder {
    pub fn new(port: u16) -> Self {
        Self { port }
    }

    pub async fn run(&self, mut shutdown: watch::Receiver<bool>) -> Result<()> {
        let addr = format!("127.0.0.1:{}", self.port);
        let socket = UdpSocket::bind(&addr).await?;
        tracing::info!("DNS responder listening on {}", addr);

        let mut buf = [0u8; 512];

        loop {
            tokio::select! {
                result = socket.recv_from(&mut buf) => {
                    let (len, src) = result?;
                    if len < 12 {
                        continue; // Too short for a DNS header
                    }
                    let response = build_response(&buf[..len]);
                    let _ = socket.send_to(&response, src).await;
                }
                _ = shutdown.changed() => {
                    tracing::info!("DNS responder shutting down");
                    break;
                }
            }
        }

        Ok(())
    }
}

/// Build a DNS response that returns 127.0.0.1 for any query.
fn build_response(query: &[u8]) -> Vec<u8> {
    let mut resp = Vec::with_capacity(query.len() + 16);

    // Copy transaction ID from query (bytes 0-1)
    resp.extend_from_slice(&query[0..2]);

    // Flags: QR=1, AA=1, RCODE=0 → 0x8400
    resp.push(0x84);
    resp.push(0x00);

    // QDCOUNT: 1
    resp.push(0x00);
    resp.push(0x01);

    // ANCOUNT: 1
    resp.push(0x00);
    resp.push(0x01);

    // NSCOUNT: 0, ARCOUNT: 0
    resp.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]);

    // Copy the question section from the query
    // Skip the 12-byte header, find the end of QNAME + QTYPE(2) + QCLASS(2)
    let question_start = 12;
    if let Some(qname_end) = find_qname_end(query, question_start) {
        let question_end = qname_end + 4; // +2 QTYPE +2 QCLASS
        if question_end <= query.len() {
            resp.extend_from_slice(&query[question_start..question_end]);

            // Answer section: pointer to QNAME in question, type A, class IN, TTL 60, 127.0.0.1
            // Name pointer: 0xC00C points to offset 12 (start of question QNAME)
            resp.extend_from_slice(&[0xC0, 0x0C]);
            // Type A (1)
            resp.extend_from_slice(&[0x00, 0x01]);
            // Class IN (1)
            resp.extend_from_slice(&[0x00, 0x01]);
            // TTL: 60 seconds
            resp.extend_from_slice(&[0x00, 0x00, 0x00, 0x3C]);
            // RDLENGTH: 4
            resp.extend_from_slice(&[0x00, 0x04]);
            // RDATA: 127.0.0.1
            resp.extend_from_slice(&[127, 0, 0, 1]);
        }
    }

    resp
}

/// Find the end of a DNS QNAME (sequence of labels ending with a zero byte).
fn find_qname_end(data: &[u8], start: usize) -> Option<usize> {
    let mut pos = start;
    while pos < data.len() {
        let label_len = data[pos] as usize;
        if label_len == 0 {
            return Some(pos + 1); // Include the zero terminator
        }
        // Bounds check: ensure the label fits within the data
        if pos + 1 + label_len > data.len() {
            return None; // Malformed: label extends past end of data
        }
        pos += 1 + label_len;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a minimal DNS query for "myapp.test" type A class IN
    fn make_dns_query(name: &str) -> Vec<u8> {
        let mut q = Vec::new();
        // Transaction ID
        q.extend_from_slice(&[0xAB, 0xCD]);
        // Flags: standard query
        q.extend_from_slice(&[0x01, 0x00]);
        // QDCOUNT: 1
        q.extend_from_slice(&[0x00, 0x01]);
        // ANCOUNT, NSCOUNT, ARCOUNT: 0
        q.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
        // QNAME: encode labels
        for label in name.split('.') {
            q.push(label.len() as u8);
            q.extend_from_slice(label.as_bytes());
        }
        q.push(0x00); // terminator
                      // QTYPE: A (1)
        q.extend_from_slice(&[0x00, 0x01]);
        // QCLASS: IN (1)
        q.extend_from_slice(&[0x00, 0x01]);
        q
    }

    #[test]
    fn test_build_response_returns_127_0_0_1() {
        let query = make_dns_query("myapp.test");
        let resp = build_response(&query);

        // Transaction ID should match
        assert_eq!(resp[0], 0xAB);
        assert_eq!(resp[1], 0xCD);

        // Flags: QR=1, AA=1 → 0x8400
        assert_eq!(resp[2], 0x84);
        assert_eq!(resp[3], 0x00);

        // QDCOUNT: 1
        assert_eq!(resp[4], 0x00);
        assert_eq!(resp[5], 0x01);

        // ANCOUNT: 1
        assert_eq!(resp[6], 0x00);
        assert_eq!(resp[7], 0x01);

        // The last 4 bytes should be 127.0.0.1
        let len = resp.len();
        assert_eq!(&resp[len - 4..], &[127, 0, 0, 1]);
    }

    #[test]
    fn test_build_response_with_subdomain() {
        let query = make_dns_query("api.myapp.test");
        let resp = build_response(&query);

        // Should still return a valid response
        assert_eq!(resp[0], 0xAB);
        assert_eq!(resp[1], 0xCD);
        let len = resp.len();
        assert_eq!(&resp[len - 4..], &[127, 0, 0, 1]);
    }

    #[test]
    fn test_find_qname_end() {
        // "myapp.test" encoded: 5 m y a p p 4 t e s t 0
        let data = [
            5, b'm', b'y', b'a', b'p', b'p', 4, b't', b'e', b's', b't', 0,
        ];
        assert_eq!(find_qname_end(&data, 0), Some(12));
    }

    #[test]
    fn test_query_with_single_label() {
        let query = make_dns_query("localhost");
        let resp = build_response(&query);
        let len = resp.len();
        assert_eq!(&resp[len - 4..], &[127, 0, 0, 1]);
    }
}
