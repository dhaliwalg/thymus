package repository

import "database/sql"

type UserRepo struct {
	db *sql.DB
}

func (r *UserRepo) FindAll() []string {
	return nil
}
