package com.example.controller;

import com.example.repository.UserRepository;
import com.example.service.UserService;
import org.springframework.stereotype.Controller;

// This controller violates boundaries by importing a repository directly
@Controller
public class BadController {
    private final UserRepository userRepository;
    private final UserService userService;

    public BadController(UserRepository userRepository, UserService userService) {
        this.userRepository = userRepository;
        this.userService = userService;
    }
}
