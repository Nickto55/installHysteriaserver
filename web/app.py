#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Hysteria UI - Web Panel for Hysteria v2 Server Management
Аналог 3x-ui для Hysteria v2
"""

import os
import sys
import json
import sqlite3
import secrets
import subprocess
import yaml
from datetime import datetime
from pathlib import Path
from flask import Flask, render_template, request, redirect, url_for, session, flash, jsonify
from werkzeug.security import generate_password_hash, check_password_hash
import qrcode
from io import BytesIO
import base64

app = Flask(__name__)
app.secret_key = secrets.token_hex(32)

# Пути
BASE_DIR = Path(__file__).parent
DB_PATH = BASE_DIR / 'hysteria.db'
HYSTERIA_CONFIG = '/etc/hysteria/config.yaml'
HYSTERIA_BIN = '/usr/local/bin/hysteria'

# ============================================================================
# База данных
# ============================================================================

def init_db():
    """Инициализация базы данных"""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    
    # Таблица администраторов
    c.execute('''CREATE TABLE IF NOT EXISTS admins (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )''')
    
    # Таблица пользователей Hysteria
    c.execute('''CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        upload_mbps INTEGER DEFAULT 100,
        download_mbps INTEGER DEFAULT 100,
        total_traffic_gb INTEGER DEFAULT 0,
        used_traffic_gb REAL DEFAULT 0,
        expiry_date TEXT,
        is_active INTEGER DEFAULT 1,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        last_online TIMESTAMP
    )''')
    
    # Таблица настроек
    c.execute('''CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT
    )''')
    
    # Создание администратора по умолчанию (admin/admin)
    try:
        c.execute("INSERT INTO admins (username, password) VALUES (?, ?)",
                  ('admin', generate_password_hash('admin')))
    except sqlite3.IntegrityError:
        pass
    
    # Настройки по умолчанию
    default_settings = {
        'server_port': '443',
        'panel_port': '54321',
        'panel_path': '/hysteria',
        'server_ip': '',
        'cert_path': '/etc/hysteria/cert.crt',
        'key_path': '/etc/hysteria/private.key'
    }
    
    for key, value in default_settings.items():
        try:
            c.execute("INSERT INTO settings (key, value) VALUES (?, ?)", (key, value))
        except sqlite3.IntegrityError:
            pass
    
    conn.commit()
    conn.close()

def get_db():
    """Получить соединение с БД"""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

# ============================================================================
# Работа с Hysteria
# ============================================================================

def generate_hysteria_config():
    """Генерация конфигурационного файла Hysteria"""
    conn = get_db()
    c = conn.cursor()
    
    # Получение настроек
    settings = {}
    for row in c.execute("SELECT key, value FROM settings"):
        settings[row['key']] = row['value']
    
    # Получение активных пользователей
    users = []
    for row in c.execute("SELECT username, password FROM users WHERE is_active = 1"):
        users.append({
            'name': row['username'],
            'auth_str': row['password']
        })
    
    conn.close()
    
    # Формирование конфигурации
    # Если есть пользователи, используем их пароли
    # Если один пользователь - строка, если несколько - массив
    if len(users) == 1:
        auth_password = users[0]['auth_str']
    elif len(users) > 1:
        auth_password = [user['auth_str'] for user in users]
    else:
        auth_password = 'changeme'
    
    config = {
        'listen': f":{settings.get('server_port', '443')}",
        'tls': {
            'cert': settings.get('cert_path', '/etc/hysteria/cert.crt'),
            'key': settings.get('key_path', '/etc/hysteria/private.key')
        },
        'auth': {
            'type': 'password',
            'password': auth_password
        },
        'masquerade': {
            'type': 'proxy',
            'proxy': {
                'url': 'https://www.bing.com',
                'rewriteHost': True
            }
        },
        'quic': {
            'initStreamReceiveWindow': 16777216,
            'maxStreamReceiveWindow': 16777216,
            'initConnReceiveWindow': 33554432,
            'maxConnReceiveWindow': 33554432,
            'maxIdleTimeout': '30s',
            'maxIncomingStreams': 1024,
            'disablePathMTUDiscovery': False
        },
        'bandwidth': {
            'up': '1 gbps',
            'down': '1 gbps'
        }
    }
    
    # Сохранение конфигурации
    try:
        os.makedirs(os.path.dirname(HYSTERIA_CONFIG), exist_ok=True)
        with open(HYSTERIA_CONFIG, 'w') as f:
            yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
        return True
    except Exception as e:
        print(f"Error generating config: {e}")
        return False

def restart_hysteria():
    """Перезапуск Hysteria сервера"""
    try:
        subprocess.run(['systemctl', 'restart', 'hysteria'], check=True)
        return True
    except subprocess.CalledProcessError:
        return False

def get_hysteria_status():
    """Получить статус Hysteria сервера"""
    try:
        result = subprocess.run(['systemctl', 'is-active', 'hysteria'], 
                                capture_output=True, text=True)
        return result.stdout.strip() == 'active'
    except:
        return False

def generate_qr_code(text):
    """Генерация QR-кода"""
    qr = qrcode.QRCode(version=1, box_size=10, border=5)
    qr.add_data(text)
    qr.make(fit=True)
    
    img = qr.make_image(fill_color="black", back_color="white")
    buffer = BytesIO()
    img.save(buffer, format='PNG')
    buffer.seek(0)
    
    img_str = base64.b64encode(buffer.getvalue()).decode()
    return f"data:image/png;base64,{img_str}"

# ============================================================================
# Декораторы
# ============================================================================

def login_required(f):
    """Декоратор для проверки авторизации"""
    from functools import wraps
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'admin_id' not in session:
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function

# ============================================================================
# Маршруты
# ============================================================================

@app.route('/login', methods=['GET', 'POST'])
def login():
    """Страница входа"""
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        
        conn = get_db()
        c = conn.cursor()
        admin = c.execute("SELECT * FROM admins WHERE username = ?", (username,)).fetchone()
        conn.close()
        
        if admin and check_password_hash(admin['password'], password):
            session['admin_id'] = admin['id']
            session['admin_username'] = admin['username']
            flash('Вход выполнен успешно!', 'success')
            return redirect(url_for('dashboard'))
        else:
            flash('Неверное имя пользователя или пароль', 'danger')
    
    return render_template('login.html')

@app.route('/logout')
def logout():
    """Выход"""
    session.clear()
    flash('Вы вышли из системы', 'info')
    return redirect(url_for('login'))

@app.route('/')
@login_required
def dashboard():
    """Главная панель"""
    conn = get_db()
    c = conn.cursor()
    
    # Статистика
    stats = {
        'total_users': c.execute("SELECT COUNT(*) FROM users").fetchone()[0],
        'active_users': c.execute("SELECT COUNT(*) FROM users WHERE is_active = 1").fetchone()[0],
        'total_traffic': c.execute("SELECT SUM(used_traffic_gb) FROM users").fetchone()[0] or 0,
        'server_status': get_hysteria_status()
    }
    
    # Последние пользователи
    recent_users = c.execute("""
        SELECT * FROM users 
        ORDER BY created_at DESC 
        LIMIT 5
    """).fetchall()
    
    conn.close()
    
    return render_template('dashboard.html', stats=stats, recent_users=recent_users)

@app.route('/users')
@login_required
def users():
    """Список пользователей"""
    conn = get_db()
    c = conn.cursor()
    
    users_list = c.execute("""
        SELECT * FROM users 
        ORDER BY created_at DESC
    """).fetchall()
    
    conn.close()
    
    return render_template('users.html', users=users_list)

@app.route('/users/add', methods=['GET', 'POST'])
@login_required
def add_user():
    """Добавление пользователя"""
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password') or secrets.token_urlsafe(16)
        upload_mbps = request.form.get('upload_mbps', 100)
        download_mbps = request.form.get('download_mbps', 100)
        total_traffic_gb = request.form.get('total_traffic_gb', 0)
        expiry_date = request.form.get('expiry_date')
        
        conn = get_db()
        c = conn.cursor()
        
        try:
            c.execute("""
                INSERT INTO users 
                (username, password, upload_mbps, download_mbps, total_traffic_gb, expiry_date) 
                VALUES (?, ?, ?, ?, ?, ?)
            """, (username, password, upload_mbps, download_mbps, total_traffic_gb, expiry_date))
            conn.commit()
            
            # Перегенерация конфигурации
            generate_hysteria_config()
            restart_hysteria()
            
            flash(f'Пользователь {username} успешно добавлен!', 'success')
            return redirect(url_for('users'))
        except sqlite3.IntegrityError:
            flash('Пользователь с таким именем уже существует', 'danger')
        finally:
            conn.close()
    
    return render_template('add_user.html')

@app.route('/users/edit/<int:user_id>', methods=['GET', 'POST'])
@login_required
def edit_user(user_id):
    """Редактирование пользователя"""
    conn = get_db()
    c = conn.cursor()
    
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        upload_mbps = request.form.get('upload_mbps')
        download_mbps = request.form.get('download_mbps')
        total_traffic_gb = request.form.get('total_traffic_gb')
        expiry_date = request.form.get('expiry_date')
        is_active = 1 if request.form.get('is_active') else 0
        
        try:
            if password:
                c.execute("""
                    UPDATE users 
                    SET username=?, password=?, upload_mbps=?, download_mbps=?, 
                        total_traffic_gb=?, expiry_date=?, is_active=?
                    WHERE id=?
                """, (username, password, upload_mbps, download_mbps, 
                      total_traffic_gb, expiry_date, is_active, user_id))
            else:
                c.execute("""
                    UPDATE users 
                    SET username=?, upload_mbps=?, download_mbps=?, 
                        total_traffic_gb=?, expiry_date=?, is_active=?
                    WHERE id=?
                """, (username, upload_mbps, download_mbps, 
                      total_traffic_gb, expiry_date, is_active, user_id))
            
            conn.commit()
            
            generate_hysteria_config()
            restart_hysteria()
            
            flash('Пользователь успешно обновлен!', 'success')
            return redirect(url_for('users'))
        except sqlite3.IntegrityError:
            flash('Пользователь с таким именем уже существует', 'danger')
        finally:
            conn.close()
    
    user = c.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
    conn.close()
    
    if not user:
        flash('Пользователь не найден', 'danger')
        return redirect(url_for('users'))
    
    return render_template('edit_user.html', user=user)

@app.route('/users/delete/<int:user_id>')
@login_required
def delete_user(user_id):
    """Удаление пользователя"""
    conn = get_db()
    c = conn.cursor()
    
    c.execute("DELETE FROM users WHERE id=?", (user_id,))
    conn.commit()
    conn.close()
    
    generate_hysteria_config()
    restart_hysteria()
    
    flash('Пользователь успешно удален!', 'success')
    return redirect(url_for('users'))

@app.route('/users/connection/<int:user_id>')
@login_required
def user_connection(user_id):
    """Информация о подключении пользователя"""
    conn = get_db()
    c = conn.cursor()
    
    user = c.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
    settings = {}
    for row in c.execute("SELECT key, value FROM settings"):
        settings[row['key']] = row['value']
    
    conn.close()
    
    if not user:
        flash('Пользователь не найден', 'danger')
        return redirect(url_for('users'))
    
    # Формирование URL
    server_ip = settings.get('server_ip', '')
    
    # Если IP не задан в настройках, пытаемся определить автоматически
    if not server_ip or server_ip == 'SERVER_IP':
        try:
            import requests
            server_ip = requests.get('https://api.ipify.org', timeout=3).text
        except:
            try:
                server_ip = subprocess.run(['curl', '-s4', 'ifconfig.me'], 
                                         capture_output=True, text=True, timeout=3).stdout.strip()
            except:
                server_ip = 'YOUR_SERVER_IP'
    
    server_port = settings.get('server_port', '443')
    hysteria_url = f"hysteria2://{user['password']}@{server_ip}:{server_port}/?insecure=1#{user['username']}"
    
    # Генерация QR-кода
    qr_code = generate_qr_code(hysteria_url)
    
    return render_template('connection.html', user=user, hysteria_url=hysteria_url, 
                           qr_code=qr_code, settings=settings)

@app.route('/settings', methods=['GET', 'POST'])
@login_required
def settings():
    """Настройки панели"""
    conn = get_db()
    c = conn.cursor()
    
    if request.method == 'POST':
        # Обновление настроек
        for key in ['server_port', 'panel_port', 'panel_path', 'server_ip', 
                    'cert_path', 'key_path']:
            value = request.form.get(key)
            if value:
                c.execute("UPDATE settings SET value=? WHERE key=?", (value, key))
        
        conn.commit()
        
        # Смена пароля администратора
        old_password = request.form.get('old_password')
        new_password = request.form.get('new_password')
        
        if old_password and new_password:
            admin = c.execute("SELECT * FROM admins WHERE id=?", 
                             (session['admin_id'],)).fetchone()
            if check_password_hash(admin['password'], old_password):
                c.execute("UPDATE admins SET password=? WHERE id=?",
                         (generate_password_hash(new_password), session['admin_id']))
                conn.commit()
                flash('Пароль успешно изменен!', 'success')
            else:
                flash('Неверный старый пароль', 'danger')
        
        generate_hysteria_config()
        restart_hysteria()
        
        flash('Настройки сохранены!', 'success')
        return redirect(url_for('settings'))
    
    settings_dict = {}
    for row in c.execute("SELECT key, value FROM settings"):
        settings_dict[row['key']] = row['value']
    
    conn.close()
    
    return render_template('settings.html', settings=settings_dict)

@app.route('/logs')
@login_required
def logs():
    """Просмотр логов"""
    try:
        result = subprocess.run(['journalctl', '-u', 'hysteria', '-n', '100', '--no-pager'],
                                capture_output=True, text=True)
        logs_content = result.stdout
    except:
        logs_content = "Не удалось загрузить логи"
    
    return render_template('logs.html', logs=logs_content)

@app.route('/api/status')
@login_required
def api_status():
    """API: статус сервера"""
    return jsonify({
        'status': 'online' if get_hysteria_status() else 'offline',
        'timestamp': datetime.now().isoformat()
    })

@app.route('/api/restart')
@login_required
def api_restart():
    """API: перезапуск сервера"""
    success = restart_hysteria()
    return jsonify({
        'success': success,
        'message': 'Сервер перезапущен' if success else 'Ошибка перезапуска'
    })

# ============================================================================
# Запуск приложения
# ============================================================================

if __name__ == '__main__':
    # Инициализация БД
    init_db()
    
    # Генерация конфигурации Hysteria
    generate_hysteria_config()
    
    # Запуск Flask
    app.run(host='0.0.0.0', port=54321, debug=False)
