package handler

import (
	"database/sql"
	"net/http"
)

// BadHandler directly accesses the database — violation
type BadHandler struct {
	db *sql.DB
}

func (h *BadHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	rows, _ := h.db.Query("SELECT * FROM users")
	_ = rows
}
