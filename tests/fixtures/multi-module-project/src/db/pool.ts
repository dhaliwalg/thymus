export const pool = {
  connections: 10,
  acquire() {
    return { id: Math.random() };
  }
};
