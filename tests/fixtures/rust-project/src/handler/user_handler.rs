use crate::service::user_service;

pub async fn get_users() -> String {
    let users = user_service::find_all();
    format!("{:?}", users)
}
