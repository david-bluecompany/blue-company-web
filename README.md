# BLUE COMPANY Web Panel

Esta es una versión funcional mínima del panel administrativo BLUE COMPANY con:

- login simple por sesión
- dashboard con métricas
- gestión de usuarios
- activación/desactivación de servicios
- auditoría básica
- almacenamiento SQLite local

## Requisitos

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Ejecutar

```bash
flask --app app run --debug
```

Luego abre:

```text
http://localhost:5000
```

## Credenciales demo

- Usuario: `admin`
- Contraseña: `admin123`

## Nota

Es un prototipo de panel administrativo. Antes de usarlo en producción hace falta:

- autenticación real con hash de contraseñas
- permisos por roles
- validación de entradas
- control de acceso a comandos del sistema
- auditoría y logs más robustos
- política de seguridad para servicios del host
