//! Raw FFI types and bindings for macOS `proc_pidinfo`.
//!
//! The `libproc` crate does not expose `PROC_PIDVNODEPATHINFO` on macOS,
//! so we define the necessary C structs and call the function directly.

extern "C" {
    pub fn proc_pidinfo(
        pid: libc::c_int,
        flavor: libc::c_int,
        arg: u64,
        buffer: *mut libc::c_void,
        buffersize: libc::c_int,
    ) -> libc::c_int;
}

pub const PROC_PIDVNODEPATHINFO: libc::c_int = 9;
pub const MAXPATHLEN: usize = 1024;

/// Mirrors Darwin's `vinfo_stat` (see bsd/sys/proc_info.h).
#[repr(C)]
pub struct VInfoStat {
    pub vst_dev: u32,
    pub vst_mode: u16,
    pub vst_nlink: u16,
    pub vst_ino: u64,
    pub vst_uid: u32,
    pub vst_gid: u32,
    pub vst_atime: i64,
    pub vst_atimensec: i64,
    pub vst_mtime: i64,
    pub vst_mtimensec: i64,
    pub vst_ctime: i64,
    pub vst_ctimensec: i64,
    pub vst_birthtime: i64,
    pub vst_birthtimensec: i64,
    pub vst_size: i64,
    pub vst_blocks: i64,
    pub vst_blksize: i32,
    pub vst_flags: u32,
    pub vst_gen: u32,
    pub vst_rdev: u32,
    pub vst_qspare: [i64; 2],
}

/// Mirrors Darwin's `vnode_info`.
#[repr(C)]
pub struct VnodeInfo {
    pub vi_stat: VInfoStat,
    pub vi_type: i32,
    pub vi_pad: i32,
    pub vi_fsid: [i32; 2],
}

/// Mirrors Darwin's `vnode_info_path`.
#[repr(C)]
pub struct VnodeInfoPath {
    pub vip_vi: VnodeInfo,
    pub vip_path: [u8; MAXPATHLEN],
}

/// Mirrors Darwin's `proc_vnodepathinfo`.
#[repr(C)]
pub struct ProcVnodePathInfo {
    pub pvi_cdir: VnodeInfoPath,
    pub pvi_rdir: VnodeInfoPath,
}
