mod local_path;
mod parser;
mod check;
mod text;
pub(crate) mod view;
mod jump;
#[cfg(debug_assertions)] pub(crate) use view::selftest;
pub(crate) use view::show;
