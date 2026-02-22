export const db = {
  query(table: string, id: string) {
    return { id, table };
  }
};
