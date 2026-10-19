// Fixed measurement units for reference clinical data (F7). The API accepts exactly these strings;
// they are also published in the OpenAPI contract (unit descriptions and x-units).
export const VITAL_UNITS = {
  hr: '/min',
  spo2: '%',
  sbp: 'mmHg',
  dbp: 'mmHg',
  temp_c: '°C',
  rr: '/min',
  crt_s: 's',
} as const;

export const LAB_UNITS = {
  haemoglobin: 'g/dL',
  haematocrit: '%',
  wbc_count: '10^9/L',
  platelet_count: '10^9/L',
} as const;
