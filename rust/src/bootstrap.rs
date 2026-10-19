//! Locates the bundled native asset so flutter_rust_bridge can open its symbols.

use std::ffi::CString;
use std::sync::OnceLock;

/// Returns the absolute path of the shared library currently executing this
/// function, as a NUL-terminated UTF-8 string, or `NULL` when the platform
/// lookup fails. The returned pointer is valid for the lifetime of the process.
#[unsafe(no_mangle)]
pub extern "C" fn openlv_ffi_bootstrap() -> *const std::os::raw::c_char {
    static PATH: OnceLock<Option<CString>> = OnceLock::new();

    let path = PATH.get_or_init(|| self_library_path().and_then(|p| CString::new(p).ok()));

    match path {
        Some(path) => path.as_ptr(),
        None => std::ptr::null(),
    }
}

#[cfg(all(unix, not(target_env = "musl")))]
fn self_library_path() -> Option<String> {
    #[repr(C)]
    struct DlInfo {
        dli_fname: *const std::os::raw::c_char,
        dli_fbase: *mut std::os::raw::c_void,
        dli_sname: *const std::os::raw::c_char,
        dli_saddr: *mut std::os::raw::c_void,
    }

    #[link(name = "dl")]
    unsafe extern "C" {
        fn dladdr(address: *const std::os::raw::c_void, info: *mut DlInfo) -> std::os::raw::c_int;
    }

    let mut info = DlInfo {
        dli_fname: std::ptr::null(),
        dli_fbase: std::ptr::null_mut(),
        dli_sname: std::ptr::null(),
        dli_saddr: std::ptr::null_mut(),
    };

    let function: extern "C" fn() -> *const std::os::raw::c_char = openlv_ffi_bootstrap;
    let address = function as *const () as *const std::os::raw::c_void;

    let success = unsafe { dladdr(address, &mut info) };
    if success == 0 || info.dli_fname.is_null() {
        return None;
    }

    let path = unsafe { std::ffi::CStr::from_ptr(info.dli_fname) };
    Some(path.to_string_lossy().into_owned())
}

#[cfg(all(unix, target_env = "musl"))]
fn self_library_path() -> Option<String> {
    // musl does not provide dladdr.
    None
}

#[cfg(windows)]
fn self_library_path() -> Option<String> {
    const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: u32 = 0x0000_0004;
    const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT: u32 = 0x0000_0002;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetModuleHandleExW(
            flags: u32,
            address: *const std::os::raw::c_void,
            module: *mut *mut std::os::raw::c_void,
        ) -> i32;
        fn GetModuleFileNameW(module: *mut std::os::raw::c_void, path: *mut u16, size: u32) -> u32;
    }

    let function: extern "C" fn() -> *const std::os::raw::c_char = openlv_ffi_bootstrap;
    let address = function as *const () as *const std::os::raw::c_void;
    let mut module = std::ptr::null_mut();

    let flags =
        GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT;
    let ok = unsafe { GetModuleHandleExW(flags, address, &mut module) };
    if ok == 0 || module.is_null() {
        return None;
    }

    let mut buffer = vec![0u16; 4096];
    let length = unsafe { GetModuleFileNameW(module, buffer.as_mut_ptr(), buffer.len() as u32) };
    if length == 0 || length as usize >= buffer.len() {
        return None;
    }

    buffer.truncate(length as usize);
    Some(String::from_utf16_lossy(&buffer))
}
