import { UserService } from '../services/user';
import { db } from '../db/client';  // violation!

export function getUser(id: string) {
  return UserService.find(id);
}
