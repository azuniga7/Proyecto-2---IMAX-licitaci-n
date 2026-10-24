# Nota de traspaso (para quien continúe con Claude)

Proyecto II BD (TEC), licitación IMAX, PostgreSQL. Ariel y su compañero turnan el chat cuando se acaban los tokens.
Reglas de Ariel: respuestas cortas, español informal, no inventar, preguntar si hay duda, NO correr pruebas ni tocar Git
(dar scripts y que él los corra en pgAdmin).

Base: scripts 01–05 (compañero), 06 vistas, 07 roles/RBAC, 08 consultas analíticas, 09_datos_prueba (compañero),
10_indices_explain, 11_app_gui (login app_imax + vistas de la GUI), 12_login_seguro (pgcrypto, contraseñas <rol>123),
pruebas/rbac_demo.sql, prueba_doble_venta.py.

GUI (carpeta gui): app.py (cliente, taquillero, operador, contador, dashboard) + admin.py (panel de administración).
Código escrito y compilado, pero NO probado contra la base (nadie lo ha corrido todavía).
Primer paso al continuar: que Ariel corra 11 y 12, luego `python app.py`, y reporte errores/capturas.

Decisiones: Flask + psycopg2 + Jinja; SET LOCAL ROLE por petición; login con bcrypt; QR como SVG generado
en el servidor (librería qrcode); mapa con polling cada 4 s; dashboard con refresco cada 15 s.

Cobertura de la pauta: ver LEEME.md. Pendiente: probar la GUI; correr scripts y sacar capturas (EXPLAIN antes/después,
concurrencia, RBAC); Fases 3 y 4 del Word; DER/modelo relacional gráfico en el repo (compañero); subir todo a Git;
preparar la demo.
Hueco conocido de la base: el trigger RN-18 de zona/asiento cubre INSERT/UPDATE/DELETE de asiento pero la zona solo
UPDATE/DELETE (INSERT de zona en una sala con ventas no se bloquea).
