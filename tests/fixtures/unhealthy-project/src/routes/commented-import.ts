// import { prisma } from '../db/client';  // This is commented out
import { UserController } from '../controllers/user.controller';
const msg = "import { prisma } from '../db/client'";  // This is a string
export const handler = { controller: new UserController() };
