import { UserService } from '../services/user';

export function registerRoutes(app: any) {
  app.get('/users/:id', (req: any, res: any) => {
    res.json(UserService.find(req.params.id));
  });
}
