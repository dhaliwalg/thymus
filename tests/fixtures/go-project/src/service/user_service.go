package service

import "github.com/example/myapp/src/repository"

type UserService struct {
	repo *repository.UserRepo
}

func (s *UserService) FindAll() []string {
	return s.repo.FindAll()
}
