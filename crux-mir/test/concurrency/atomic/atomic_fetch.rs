extern crate crucible;
use crucible::*;
use std::thread;
use std::sync::{Arc,atomic};

#[cfg(not(with_main))]
#[cfg_attr(crux, crux_test)]
fn crux_test_nofail() {
    let N       = 3;

    let cell        = Arc::new(atomic::AtomicU16::new(0));
    let mut threads = vec![];

    for x in 0..N {
        let d = Arc::clone(&cell);
        let c = thread::spawn(move || {
            d.fetch_add(x, atomic::Ordering::SeqCst);
        });
        threads.push(c);
    }

    for t in threads {
        t.join();
    }

    let val = cell.load(atomic::Ordering::SeqCst);
    crucible_assert!(val == N*(N-1)/2);
}

#[cfg(with_main)]
fn main() {}
