# AIS test fixture — db layer (permitted to have raw SQL)
import sqlite3

def get_connection():
    return sqlite3.connect("app.db")

def execute_raw(sql: str):
    # Raw SQL is allowed here — this file is in the excluded scope
    conn = get_connection()
    return conn.execute(sql)
