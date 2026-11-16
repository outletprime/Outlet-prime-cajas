// Simulador: escribe en la ventana  "tiktok ana_23 quiero la 23"  y se procesa como un comentario.
// Las usuarias simuladas quedan como sim_… y se borran con "Borrar datos de prueba" del panel.
import readline from 'node:readline';
import { nuevoEstado } from './comun.js';

export function crearSimulador(eventos, entrada = process.stdin) {
  const estado = nuevoEstado('simulador', 'Escribe: red usuario comentario');
  let rl;
  let n = 0;
  return {
    estado,
    iniciar() {
      estado.estado = 'conectado';
      eventos.enVivo('simulador');
      rl = readline.createInterface({ input: entrada });
      rl.on('line', linea => {
        const [red, usuario, ...resto] = linea.trim().split(/\s+/);
        if (!red || !usuario || !resto.length) return;
        eventos.comentario({ red: red.toLowerCase(), usuario, nombre: usuario, texto: resto.join(' '), id: `sim-${Date.now()}-${++n}`, fecha: new Date(), simulado: true });
      });
      rl.on('close', () => { estado.estado = 'apagado'; eventos.finSimulador?.(); });
    },
    async detener() { rl?.close(); },
  };
}
