use std::sync::Arc;

#[cfg_attr(crux, crux::test)]
fn crux_test() -> i32 {
    let a = Arc::new(1);
    let b = a.clone();
    *a + *b
}

pub fn main() {
    println!("{:?}", crux_test());
}
