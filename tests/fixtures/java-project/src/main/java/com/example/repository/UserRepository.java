package com.example.repository;

import com.example.model.User;
import java.util.List;

public interface UserRepository {
    List<User> findAll();
    User findById(Long id);
}
