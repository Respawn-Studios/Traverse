// Isolated temporary-catalog candidate. It is absent from ordinary worker flags.
#[cfg(not(all(b06_checkpoint4096,b06_live_totals)))]
compile_error!("Adaptive checkpoint qualification requires the committed4096 baseline");

fn adaptive_checkpoint_due(count:u64,committed:u64,elapsed_ns:u128)->bool {
    let Some(pending)=count.checked_sub(committed) else{return false;};
    pending>=4096 && (committed==0 || pending>=16384 || elapsed_ns>=250_000_000)
}

#[cfg(test)]
mod adaptive_checkpoint_tests {
    use super::adaptive_checkpoint_due as due;
    #[test] fn first_prefix_and_pending_row_bound_are_exact() {
        assert!(!due(0,0,u128::MAX));assert!(!due(4095,0,u128::MAX));
        assert!(due(4096,0,0));assert!(due(4097,0,0));
        assert!(!due(4096,4096,u128::MAX));assert!(!due(8191,4096,u128::MAX));
        assert!(!due(20479,4096,0));assert!(due(20480,4096,0));
        assert!(!due(1,2,u128::MAX));assert!(!due(u64::MAX,u64::MAX,u128::MAX));
        assert!(due(u64::MAX,u64::MAX-16384,0));
    }
    #[test] fn slow_path_never_commits_an_incomplete_minimum() {
        assert!(!due(8192,4096,249_999_999));assert!(due(8192,4096,250_000_000));
        assert!(due(8192,4096,u128::MAX));assert!(!due(8191,4096,u128::MAX));
        assert!(!due(12287,8192,u128::MAX));assert!(due(12288,8192,250_000_000));
    }
}
