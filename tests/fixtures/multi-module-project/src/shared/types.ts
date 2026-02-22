export interface User {
  id: string;
  name: string;
}

export interface Session {
  token: string;
  userId: string;
}
