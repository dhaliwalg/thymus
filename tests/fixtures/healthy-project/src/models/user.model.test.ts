import { User } from './user.model';
test('User interface', () => { const u: User = { id: '1', email: 'a@b.com' }; expect(u.id).toBeDefined(); });
