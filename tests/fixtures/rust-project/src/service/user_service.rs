use crate::repository::user_repo;

pub fn find_all() -> Vec<String> {
    user_repo::find_all()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_find_all() {
        let result = find_all();
        assert!(result.is_empty());
    }
}
