import { log } from './logger';
test('log function', () => { expect(() => log('test')).not.toThrow(); });
