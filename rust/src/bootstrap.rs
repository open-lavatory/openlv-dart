//! Bridge Dart's asset-id lookup to the `DynamicLibrary` handle UniFFI needs.
//!
//! Dart native assets let Dart call this symbol by asset ID, but the generated
//! UniFFI bindings need a library path to open. Returning the file that contains
//! this function makes the loader open the exact native asset Dart loaded.
use std::{ffi::CString, sync::LazyLock};

#[unsafe(no_mangle)]
pub extern "C" fn openlv_ffi_bootstrap() -> *const std::os::raw::c_char {
    // The pointer must remain valid after this function returns.
    static PATH: LazyLock<Option<CString>> =
        LazyLock::new(|| self_library_path().and_then(|path| CString::new(path).ok()));
    PATH.as_ref().map_or(std::ptr::null(), |path| path.as_ptr())
}

#[cfg(all(unix, not(target_env = "musl")))]
fn self_library_path() -> Option<String> {
    // `dladdr` maps a function address to the shared object containing it.
    // This struct mirrors the C `Dl_info` layout required by that API.
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
    let address = openlv_ffi_bootstrap as *const () as *const std::os::raw::c_void;
    if unsafe { dladdr(address, &mut info) } == 0 || info.dli_fname.is_null() {
        return None;
    }
    Some(
        unsafe { std::ffi::CStr::from_ptr(info.dli_fname) }
            .to_string_lossy()
            .into_owned(),
    )
}

#[cfg(all(unix, target_env = "musl"))]
fn self_library_path() -> Option<String> {
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
    let address = openlv_ffi_bootstrap as *const () as *const std::os::raw::c_void;
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
