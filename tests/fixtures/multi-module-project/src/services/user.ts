import { db } from '../db/client';

export class UserService {
  static find(id: string) {
    return db.query('users', id);
  }
}
