import { prisma } from '../db/client';  // VIOLATION: route accessing db directly
import { UserController } from '../controllers/user.controller';
export const userRouter = { controller: new UserController(), db: prisma };
