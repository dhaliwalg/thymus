use sqlx::PgPool;
use axum::extract::State;

pub async fn bad_handler(State(pool): State<PgPool>) -> String {
    let _rows = sqlx::query("SELECT * FROM users")
        .fetch_all(&pool)
        .await;
    "ok".to_string()
}
