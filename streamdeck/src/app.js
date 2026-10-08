/*
 * Asks Busy Bar Sign, on this Mac, what the sign says
 * (Sources/LocalAPI.swift has the details).
 *
 *   getStatus()  {"state":"call","moment":{"at":1760000000000,"kind":"countdown"},"dnd":false}
 *   toggleDND()  as a double-click on the bar; resolves to the new status
 */
import http from 'node:http';

export const PORT = Number(process.env.BUSY_BAR_SIGN_PORT) || 47811;

function ask(method, path) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: '127.0.0.1', port: PORT, method, path, agent: false, timeout: 800,
      headers: { 'Content-Length': 0 }
    }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (part) => { body += part; });
      res.on('end', () => {
        if (res.statusCode !== 200) return reject(new Error(`${method} ${path}: HTTP ${res.statusCode}`));
        try {
          const status = JSON.parse(body);
          if (typeof status.state !== 'string') throw new Error('no state');
          resolve({ state: status.state, moment: status.moment || null, dnd: !!status.dnd });
        } catch (e) {
          reject(new Error(`${method} ${path}: unreadable answer (${e.message})`));
        }
      });
    });
    req.on('timeout', () => req.destroy(new Error(`${method} ${path}: no answer`)));
    req.on('error', reject);
    req.end();
  });
}

export const getStatus = () => ask('GET', '/status');
export const toggleDND = () => ask('POST', '/dnd/toggle');
