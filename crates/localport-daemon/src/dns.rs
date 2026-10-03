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
                    if let Some(response) = build_response(&buf[..len]) {
                        let _ = socket.send_to(&response, src).await;
                    }
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

const TYPE_A: [u8; 2] = [0x00, 0x01];
const CLASS_IN: [u8; 2] = [0x00, 0x01];

/// Build a DNS response for `query`, or `None` if it should be ignored.
///
/// `A`/`IN` queries are answered with 127.0.0.1. Every other type (notably
/// `AAAA`) gets an empty NOERROR ("no data") answer, so resolvers fall back to
/// the A record instead of waiting on a mismatched or missing reply.
/// Malformed queries get FORMERR; responses (QR=1) are ignored.
fn build_response(query: &[u8]) -> Option<Vec<u8>> {
    if query.len() < 12 || query[2] & 0x80 != 0 {
        return None; // too short for a header, or not a query
    }
    let rd = query[2] & 0x01;
    let qdcount = u16::from_be_bytes([query[4], query[5]]);

    let mut resp = Vec::with_capacity(query.len() + 16);
    resp.extend_from_slice(&query[0..2]); // transaction ID

    let question = (qdcount == 1)
        .then(|| find_qname_end(query, 12))
        .flatten()
        .map(|qname_end| qname_end + 4) // +2 QTYPE +2 QCLASS
        .filter(|&end| end <= query.len())
        .map(|end| &query[12..end]);

    let Some(question) = question else {
        // FORMERR: QR=1, AA=1, RD copied, RCODE=1; no sections.
        resp.extend_from_slice(&[0x84 | rd, 0x01, 0, 0, 0, 0, 0, 0, 0, 0]);
        return Some(resp);
    };

    let qtail = &question[question.len() - 4..];
    let answer_a = qtail[..2] == TYPE_A && qtail[2..] == CLASS_IN;

    // Flags: QR=1, AA=1, RD copied, RCODE=0
    resp.extend_from_slice(&[0x84 | rd, 0x00]);
    resp.extend_from_slice(&[0x00, 0x01]); // QDCOUNT
    resp.extend_from_slice(&[0x00, answer_a as u8]); // ANCOUNT
    resp.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]); // NSCOUNT, ARCOUNT
    resp.extend_from_slice(question);

    if answer_a {
        // Name pointer: 0xC00C points to offset 12 (start of question QNAME)
        resp.extend_from_slice(&[0xC0, 0x0C]);
        resp.extend_from_slice(&TYPE_A);
        resp.extend_from_slice(&CLASS_IN);
        resp.extend_from_slice(&[0x00, 0x00, 0x00, 0x3C]); // TTL: 60 seconds
        resp.extend_from_slice(&[0x00, 0x04]); // RDLENGTH
        resp.extend_from_slice(&[127, 0, 0, 1]);
    }

    Some(resp)
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
        make_dns_query_type(name, 1)
    }

    fn make_dns_query_type(name: &str, qtype: u8) -> Vec<u8> {
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
        q.extend_from_slice(&[0x00, qtype]); // QTYPE
                                             // QCLASS: IN (1)
        q.extend_from_slice(&[0x00, 0x01]);
        q
    }

    #[test]
    fn test_build_response_returns_127_0_0_1() {
        let query = make_dns_query("myapp.test");
        let resp = build_response(&query).unwrap();

        // Transaction ID should match
        assert_eq!(resp[0], 0xAB);
        assert_eq!(resp[1], 0xCD);

        // Flags: QR=1, AA=1, RD copied → 0x8500
        assert_eq!(resp[2], 0x85);
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
        let resp = build_response(&query).unwrap();

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
        let resp = build_response(&query).unwrap();
        let len = resp.len();
        assert_eq!(&resp[len - 4..], &[127, 0, 0, 1]);
    }

    #[test]
    fn test_aaaa_query_gets_empty_noerror() {
        let query = make_dns_query_type("myapp.test", 28);
        let resp = build_response(&query).unwrap();
        assert_eq!(resp[3] & 0x0F, 0, "RCODE should be NOERROR");
        assert_eq!(&resp[6..8], &[0, 0], "ANCOUNT should be 0");
        assert_eq!(resp.len(), query.len(), "header + question only");
    }

    #[test]
    fn test_malformed_query_gets_formerr() {
        let mut query = make_dns_query("myapp.test");
        query.truncate(15); // cut through the QNAME
        let resp = build_response(&query).unwrap();
        assert_eq!(resp[3] & 0x0F, 1, "RCODE should be FORMERR");
        assert_eq!(resp.len(), 12);
    }

    #[test]
    fn test_ignores_responses_and_short_packets() {
        let mut query = make_dns_query("myapp.test");
        query[2] |= 0x80; // QR=1
        assert!(build_response(&query).is_none());
        assert!(build_response(&[0u8; 5]).is_none());
    }
}
