//! Native messaging framing: a 4-byte little-endian length, then UTF-8 JSON.
use std::io::{self, Read, Write};

pub const MAX_MESSAGE: usize = 1 << 20;

#[derive(Debug)]
pub enum FrameError {
    Eof,
    TooLarge(u32),
    Io(io::Error),
}

/// An oversize body is drained so the next frame still lines up.
pub fn read_frame<R: Read>(r: &mut R) -> Result<Vec<u8>, FrameError> {
    let mut header = [0u8; 4];
    match r.read_exact(&mut header) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Err(FrameError::Eof),
        Err(e) => return Err(FrameError::Io(e)),
    }
    let len = u32::from_le_bytes(header);
    if len as usize > MAX_MESSAGE {
        io::copy(&mut r.by_ref().take(u64::from(len)), &mut io::sink()).map_err(FrameError::Io)?;
        return Err(FrameError::TooLarge(len));
    }
    let mut body = vec![0u8; len as usize];
    r.read_exact(&mut body).map_err(FrameError::Io)?;
    Ok(body)
}

pub fn write_frame<W: Write>(w: &mut W, payload: &[u8]) -> io::Result<()> {
    if payload.len() > MAX_MESSAGE {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "message exceeds 1 MiB"));
    }
    w.write_all(&(payload.len() as u32).to_le_bytes())?;
    w.write_all(payload)?;
    w.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_is_little_endian() {
        let mut out = Vec::new();
        write_frame(&mut out, b"hi").unwrap();
        assert_eq!(out, [2, 0, 0, 0, b'h', b'i']);
        assert_eq!(read_frame(&mut &[1u8, 0, 0, 0, b'x'][..]).unwrap(), b"x");
    }

    #[test]
    fn round_trip_keeps_utf8() {
        let mut out = Vec::new();
        let msg = "{\"urls\":[\"https://a.com/é.zip\"]}".as_bytes();
        write_frame(&mut out, msg).unwrap();
        assert_eq!(read_frame(&mut out.as_slice()).unwrap(), msg);
    }

    #[test]
    fn empty_input_is_eof() {
        assert!(matches!(read_frame(&mut &[][..]), Err(FrameError::Eof)));
    }

    #[test]
    fn truncated_body_is_io_error() {
        let mut input = &[5u8, 0, 0, 0, b'a'][..];
        assert!(matches!(read_frame(&mut input), Err(FrameError::Io(_))));
    }

    #[test]
    fn oversize_read_is_rejected_and_drained() {
        let n = MAX_MESSAGE + 1;
        let mut input = (n as u32).to_le_bytes().to_vec();
        input.resize(4 + n, 0);
        write_frame(&mut input, b"ok").unwrap();
        let mut r = input.as_slice();
        assert!(matches!(read_frame(&mut r), Err(FrameError::TooLarge(l)) if l as usize == n));
        assert_eq!(read_frame(&mut r).unwrap(), b"ok");
    }

    #[test]
    fn oversize_write_is_rejected() {
        let mut out = Vec::new();
        let big = vec![b'a'; MAX_MESSAGE + 1];
        assert!(write_frame(&mut out, &big).is_err());
        assert!(out.is_empty());
    }
}
