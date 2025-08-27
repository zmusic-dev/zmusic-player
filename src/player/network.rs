use symphonia::core::io::MediaSource;

/// 网络媒体源
pub struct NetworkMediaSource {
    url: String,
    reader: Option<Box<dyn std::io::Read + Send + Sync>>,
}

impl NetworkMediaSource {
    /// 创建网络媒体源
    pub fn new(url: String) -> std::result::Result<Self, Box<dyn std::error::Error>> {
        Ok(Self { url, reader: None })
    }

    /// 初始化读取器
    fn ensure_reader(&mut self) -> std::result::Result<(), Box<dyn std::error::Error>> {
        if self.reader.is_none() {
            let response = ureq::get(&self.url).call()?;
            self.reader = Some(Box::new(response.into_reader()));
        }
        Ok(())
    }
}

impl MediaSource for NetworkMediaSource {
    /// 是否可随机访问
    fn is_seekable(&self) -> bool {
        false
    }

    /// 文件大小
    fn byte_len(&self) -> Option<u64> {
        None
    }
}

impl std::io::Read for NetworkMediaSource {
    /// 读取
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.ensure_reader()
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?;

        if let Some(ref mut reader) = self.reader {
            reader.read(buf)
        } else {
            Ok(0)
        }
    }
}

impl std::io::Seek for NetworkMediaSource {
    fn seek(&mut self, _pos: std::io::SeekFrom) -> std::io::Result<u64> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "Network streams do not support seeking",
        ))
    }
}


