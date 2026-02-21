package handler

import (
	"net/http"

	"github.com/example/myapp/src/service"
)

type UserHandler struct {
	svc *service.UserService
}

func (h *UserHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	_ = h.svc.FindAll()
}
