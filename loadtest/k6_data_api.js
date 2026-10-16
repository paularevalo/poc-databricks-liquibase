// Prueba de capacidad del Lakebase Data API (solo lectura).
//
// Objetivo: encontrar el MÁXIMO TPS SOSTENIDO que cumple el SLO durante un escalón
// completo — no el pico antes de romperse.
//
// Perfil: calentamiento (descartado) → escalones de tasa fija (ramping-arrival-rate).
// Cada request se etiqueta con el escalón al que pertenece; al final se evalúa el SLO
// por escalón: p95 < SLO_P95_MS, errores < SLO_ERROR_PCT y tasa lograda >= 95% de la objetivo.
//
// Variables de entorno:
//   DATA_API_URL, DATA_API_TOKEN          (obligatorias)
//   PASOS="25,50,100,200,400"             tasas objetivo (TPS) por escalón
//   DURACION_PASO_S=300                   segundos sostenidos por escalón
//   RAMPA_S=15                            segundos de transición entre escalones (no se evalúan)
//   CALENTAMIENTO_S=120                   segundos iniciales descartados (cold start, caché)
//   SLO_P95_MS=300  SLO_ERROR_PCT=1
//   MAX_VUS=400                           tope de usuarios virtuales concurrentes
//   NUM_ATENCIONES=100000  NUM_PACIENTES=10000   rango de IDs aleatorios

import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';

const URL = (__ENV.DATA_API_URL || '').replace(/\/$/, '');
const TOKEN = __ENV.DATA_API_TOKEN || '';
const PASOS = (__ENV.PASOS || '25,50,100,200,400').split(',').map((x) => parseInt(x.trim(), 10));
const DUR = parseInt(__ENV.DURACION_PASO_S || '300', 10);
const RAMPA = parseInt(__ENV.RAMPA_S || '15', 10);
const WARM = parseInt(__ENV.CALENTAMIENTO_S || '120', 10);
const SLO_P95 = parseFloat(__ENV.SLO_P95_MS || '300');
const SLO_ERR = parseFloat(__ENV.SLO_ERROR_PCT || '1');
const MAX_VUS = parseInt(__ENV.MAX_VUS || '400', 10);
const N_AT = parseInt(__ENV.NUM_ATENCIONES || '100000', 10);
const N_PAC = parseInt(__ENV.NUM_PACIENTES || '10000', 10);

// --- Línea de tiempo: [calentamiento][rampa+paso1][rampa+paso2]...
const stages = [{ target: PASOS[0], duration: `${WARM}s` }];
const ventanas = []; // {tasa, desde, hasta} en segundos desde el inicio
let t = WARM;
for (const tasa of PASOS) {
  stages.push({ target: tasa, duration: `${RAMPA}s` });
  stages.push({ target: tasa, duration: `${DUR}s` });
  ventanas.push({ tasa, desde: t + RAMPA, hasta: t + RAMPA + DUR });
  t += RAMPA + DUR;
}

// Umbrales por escalón: obligan a k6 a reportar submétricas por etiqueta "paso".
// abortOnFail=false: no cortamos la prueba, solo medimos.
const thresholds = {};
for (const { tasa } of ventanas) {
  thresholds[`http_req_duration{paso:${tasa}}`] = [{ threshold: `p(95)<${SLO_P95}`, abortOnFail: false }];
  thresholds[`http_req_failed{paso:${tasa}}`] = [{ threshold: `rate<${SLO_ERR / 100}`, abortOnFail: false }];
  thresholds[`http_reqs{paso:${tasa}}`] = ['count>=0'];
}

export const options = {
  discardResponseBodies: false,
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds,
  scenarios: {
    escalones: {
      executor: 'ramping-arrival-rate',
      startRate: Math.max(1, Math.floor(PASOS[0] / 2)),
      timeUnit: '1s',
      preAllocatedVUs: Math.min(MAX_VUS, Math.max(10, PASOS[0])),
      maxVUs: MAX_VUS,
      stages,
    },
  },
};

const HEADERS = { Authorization: `Bearer ${TOKEN}` };

function pasoActual() {
  const s = (Date.now() - exec.scenario.startTime) / 1000;
  for (const v of ventanas) if (s >= v.desde && s < v.hasta) return String(v.tasa);
  return s < WARM ? 'calentamiento' : 'rampa';
}

const rnd = (n) => Math.floor(Math.random() * n) + 1;
const pac = () => `PAC-${String(rnd(N_PAC)).padStart(7, '0')}`;
const SERVICIOS = ['Medicina%20general', 'Emergencia', 'Pediatr%C3%ADa', 'Cardiolog%C3%ADa', 'Neumolog%C3%ADa'];

// Mezcla de consultas (hipótesis; ajústala a tu patrón real)
const CONSULTAS = [
  { peso: 60, nombre: 'pk', ruta: () => `/public/atenciones?atencion_id=eq.${rnd(N_AT)}` },
  { peso: 25, nombre: 'historial', ruta: () => `/public/atenciones?paciente_id=eq.${pac()}&order=fecha_atencion.desc&limit=20&select=atencion_id,fecha_atencion,servicio,diagnostico_codigo` },
  { peso: 10, nombre: 'paciente', ruta: () => `/public/pacientes?paciente_id=eq.${pac()}` },
  { peso: 5, nombre: 'filtro', ruta: () => `/public/atenciones?servicio=eq.${SERVICIOS[rnd(SERVICIOS.length) - 1]}&limit=10&select=atencion_id,paciente_id` },
];
const TOTAL = CONSULTAS.reduce((a, c) => a + c.peso, 0);
function elegirConsulta() {
  let r = Math.random() * TOTAL;
  for (const c of CONSULTAS) { if ((r -= c.peso) < 0) return c; }
  return CONSULTAS[0];
}

export function setup() {
  if (!URL || !TOKEN) throw new Error('Faltan DATA_API_URL o DATA_API_TOKEN');
  const r = http.get(`${URL}/public/atenciones?limit=1`, { headers: HEADERS });
  if (r.status !== 200) throw new Error(`Verificación previa falló: HTTP ${r.status} ${r.body}`);
  return { inicio: new Date().toISOString() };
}

export default function () {
  const c = elegirConsulta();
  const res = http.get(URL + c.ruta(), { headers: HEADERS, tags: { paso: pasoActual(), consulta: c.nombre } });
  check(res, { 'HTTP 200': (r) => r.status === 200 });
}

// --- Evaluación por escalón y reporte
export function handleSummary(data) {
  const m = data.metrics;
  const filas = [];
  let garantizado = null;
  let roto = false;
  for (const { tasa } of ventanas) {
    const dur = m[`http_req_duration{paso:${tasa}}`];
    const err = m[`http_req_failed{paso:${tasa}}`];
    const cnt = m[`http_reqs{paso:${tasa}}`];
    const n = cnt ? cnt.values.count : 0;
    const logrado = n / DUR;
    const p95 = dur ? dur.values['p(95)'] : NaN;
    const p99 = dur ? dur.values['p(99)'] : NaN;
    const errPct = err ? err.values.rate * 100 : NaN;
    const okLat = p95 < SLO_P95;
    const okErr = errPct < SLO_ERR;
    const okTasa = logrado >= 0.95 * tasa;
    const ok = n > 0 && okLat && okErr && okTasa;
    if (ok && !roto) garantizado = tasa; else if (!ok) roto = true;
    filas.push({ tasa, logrado, p95, p99, errPct, ok, okLat, okErr, okTasa });
  }

  const f = (x, d = 1) => (Number.isFinite(x) ? x.toFixed(d) : 'n/a');
  let md = `## Resultado de capacidad — Lakebase Data API\n\n`;
  md += `SLO: p95 < ${SLO_P95} ms, errores < ${SLO_ERR}%, tasa lograda ≥ 95% de la objetivo, sostenido ${DUR}s por escalón.\n\n`;
  md += garantizado
    ? `### ✅ TPS máximo garantizado: **${garantizado}**\n\n`
    : `### ❌ Ningún escalón cumplió el SLO (empieza con tasas más bajas)\n\n`;
  md += `| TPS objetivo | TPS logrado | p95 ms | p99 ms | errores % | ¿cumple? |\n|---:|---:|---:|---:|---:|:--|\n`;
  for (const r of filas) {
    const motivo = r.ok ? '✅' : `❌ ${[!r.okLat && 'latencia', !r.okErr && 'errores', !r.okTasa && 'tasa'].filter(Boolean).join(', ')}`;
    md += `| ${r.tasa} | ${f(r.logrado)} | ${f(r.p95, 0)} | ${f(r.p99, 0)} | ${f(r.errPct, 2)} | ${motivo} |\n`;
  }
  const drop = m.dropped_iterations ? m.dropped_iterations.values.count : 0;
  md += `\nIteraciones descartadas por falta de VUs: ${drop}${drop > 0 ? ' (sube MAX_VUS si el cuello fue el generador)' : ''}.\n`;
  md += `\n> Mide la latencia **extremo a extremo desde el runner**: incluye red. Vale solo para este compute y este dataset.\n`;

  return {
    stdout: md,
    'resultado.md': md,
    'resultado.json': JSON.stringify({ garantizado, slo: { p95_ms: SLO_P95, error_pct: SLO_ERR }, pasos: filas }, null, 2),
    'k6-summary.json': JSON.stringify(data, null, 2),
  };
}
