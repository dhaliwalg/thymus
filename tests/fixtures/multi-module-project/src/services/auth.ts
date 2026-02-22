import { db } from '../db/client';

export class AuthService {
  static verify(token: string) {
    return db.query('sessions', token);
  }
}
