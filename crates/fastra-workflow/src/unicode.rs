// Dieselbe gepinnte ICU-ABI wie fastra-core; keine zweite Unicode-Tabelle.
#[link(name = "icuuc")]
unsafe extern "C" {
    #[link_name = "u_charType_78"]
    fn category(character: i32) -> i8;
}
pub(crate) fn control(character: char) -> bool {
    // U_CONTROL_CHAR und U_FORMAT_CHAR bilden Foundations controlCharacters.
    matches!(unsafe { category(character as i32) }, 15 | 16)
}
pub(crate) fn horizontal_space(character: char) -> bool {
    character == '\t' || unsafe { category(character as i32) } == 12
}
