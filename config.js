/* Configuración compartida por la app de Cajas (index.html) y el panel del live (live.html).
 * Conexión con la base de datos de Supabase (proyecto "outlet-prime").
 * La llave "anon" es pública: solo deja entrar a quien inicia sesión con su correo y contraseña.
 * NUNCA pongas aquí la llave "service_role". */
window.APP_CONFIG = {
  nombreNegocio: 'Outlet Prime',
  supabaseUrl: 'https://fjafsvirllfuzrzonovy.supabase.co',
  supabaseAnonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZqYWZzdmlybGxmdXpyem9ub3Z5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQxMTM5NzEsImV4cCI6MjEwOTY4OTk3MX0.rN7gVhHbiy3T0mSStHKPWzUH1YD9qoTv9VYmUAbDYJI',
  diasAlerta: 20,
  diasAviso: 15,
  limiteVideoMB: 48,
  vistaPrevia: false,
};
