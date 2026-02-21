# AIS test fixture — intentional boundary violation
# This route imports directly from db instead of going through a repository

from src.db.client import get_connection  # VIOLATION: should use src/repositories/

def get_user(user_id: int):
    conn = get_connection()
    # Direct raw SQL in route — forbidden outside db layer
    conn.execute("DELETE FROM sessions WHERE expired = 1")
    return conn.execute("SELECT id, name FROM users WHERE id = ?", [user_id]).fetchone()
