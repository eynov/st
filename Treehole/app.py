from flask import Flask, request, render_template, jsonify, redirect, url_for, Response, send_from_directory, session, flash
from flask_login import LoginManager, login_user, login_required, logout_user, UserMixin, current_user
import os
import smtplib
import requests
import uuid
import secrets
import hashlib
import threading
from email.message import EmailMessage
from werkzeug.utils import secure_filename
from datetime import datetime, timezone
from config import *
from models import db, Message, Attachment

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "supersecret")
app.config['UPLOAD_FOLDER'] = 'uploads'
basedir = os.path.abspath(os.path.dirname(__file__))
db_path = os.path.join(basedir, 'instance', 'treehole.db')
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///' + db_path
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
db.init_app(app)
os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)

login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = "login"
login_manager.login_message = None

# ----- Login User Model -----
class AdminUser(UserMixin):
    def __init__(self, id):
        self.id = id

@login_manager.user_loader
def load_user(user_id):
    return AdminUser(user_id)

def allowed_file(filename):
    ALLOWED_EXTENSIONS = {'png', 'jpg', 'jpeg', 'gif', 'mp3', 'mp4', 'wav', 'mov'}
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS


# ===== 🔒 现代无感人机验证逻辑 (PoW) =====
def generate_pow_challenge():
    """生成一个随机盐值，要求前端找出 nonce 使得 md5(salt + nonce) 以 '000' 开头"""
    salt = secrets.token_hex(8)
    session['pow_salt'] = salt
    return salt

def verify_pow(nonce):
    """验证前端计算的 PoW 答案"""
    salt = session.get('pow_salt')
    if not salt or not nonce:
        return False
    # 清除当前 salt，防止重放攻击
    session.pop('pow_salt', None)
    
    target_str = f"{salt}{nonce}"
    result_hash = hashlib.md5(target_str.encode()).hexdigest()
    # 验证哈希前 3 位是否为 000 (可根据防刷严格度调成 0000)
    return result_hash.startswith('000')


# ----- Email & Telegram -----
def send_email(subject, body, filepaths=None, to_email=None):
    try:
        msg = EmailMessage()
        msg['Subject'] = subject
        msg['From'] = EMAIL_SENDER
        msg['To'] = to_email or EMAIL_RECEIVER
        msg.set_content("You have a new anonymous message.")
        msg.add_alternative(f"<html><body><p>{body.replace('\n', '<br>')}</p></body></html>", subtype='html')
        
        if filepaths:
            import mimetypes
            for path in filepaths:
                if os.path.exists(path):
                    with open(path, 'rb') as f:
                        data = f.read()
                        name = os.path.basename(path)
                    mime_type, _ = mimetypes.guess_type(path)
                    maintype, subtype = mime_type.split('/', 1) if mime_type else ('application', 'octet-stream')
                    msg.add_attachment(data, maintype=maintype, subtype=subtype, filename=name)
                    
        with smtplib.SMTP(EMAIL_SMTP_SERVER, EMAIL_SMTP_PORT) as smtp:
            smtp.starttls()
            smtp.login(EMAIL_SENDER, EMAIL_PASSWORD)
            smtp.send_message(msg)
    except Exception as e:
        print(f"[ERROR] Email failed: {e}")

def send_telegram(text, chat_id=None):
    try:
        url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
        data = {'chat_id': chat_id or ADMIN_USER_ID, 'text': text, 'parse_mode': 'HTML'}
        requests.post(url, data=data, timeout=10)
    except Exception as e:
        print(f"[ERROR] Telegram failed: {e}")

def send_telegram_files(filepaths, chat_id=None):
    try:
        for path in filepaths:
            if os.path.exists(path):
                url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendDocument"
                with open(path, 'rb') as f:
                    files = {'document': f}
                    data = {'chat_id': chat_id or ADMIN_USER_ID}
                    requests.post(url, files=files, data=data, timeout=15)
    except Exception as e:
        print(f"[ERROR] Telegram files failed: {e}")

def async_notification_worker(notice, saved_paths):
    send_telegram(notice)
    if saved_paths:
        send_telegram_files(saved_paths)
    send_email("🌿 Anonymous Message", notice, filepaths=saved_paths)


# ========================= Routes ==========================

@app.route('/', methods=['GET'])
def index():
    # 每次进入页面，生成一个新鲜的 PoW 盐值传给前端
    pow_salt = generate_pow_challenge()
    return render_template('index.html', pow_salt=pow_salt)

@app.route('/', methods=['POST'])
def submit():
    # 1. 蜜罐拦截：全自动机器人通常会盲填所有表单
    if request.form.get('username_fake', ''):
        return jsonify({'success': False, 'message': 'Bot detected.'}), 400

    # 2. 验证后台无感 PoW 算力人机验证
    user_nonce = request.form.get('pow_nonce', '')
    if not verify_pow(user_nonce):
        return jsonify({'success': False, 'message': 'Security check failed. Please refresh.'}), 400

    message_text = request.form.get('message', '').strip()
    email = request.form.get('email', '').strip()
    tg_id = request.form.get('telegram_id', '').strip()
    files = request.files.getlist('file[]')

    if not message_text and not any(f.filename for f in files):
        return jsonify({'success': False, 'message': 'Message is empty.'}), 400

    msg = Message(message=message_text, email=email, telegram_id=tg_id)
    db.session.add(msg)
    db.session.commit()

    saved_paths = []
    for file in files:
        if file and allowed_file(file.filename):
            ext = file.filename.rsplit('.', 1)[1].lower()
            unique_filename = f"{uuid.uuid4().hex}.{ext}"
            filepath = os.path.join(app.config['UPLOAD_FOLDER'], unique_filename)
            file.save(filepath)
            saved_paths.append(filepath)
            
            attachment = Attachment(message_id=msg.id, filename=unique_filename)
            db.session.add(attachment)
    db.session.commit()

    notice = "<b>🌿 Anonymous Message</b>"
    if message_text:
        notice += f"\n\n{message_text}"
    if email:
        notice += f"\n📧 Email: {email}"
    if tg_id:
        notice += f"\n📨 Telegram: {tg_id}"

    # 异步多线程发送，避免卡顿
    threading.Thread(target=async_notification_worker, args=(notice, saved_paths), daemon=True).start()

    return jsonify({'success': True, 'message': 'Message sent! Thank you.'})

# --- 其余管理端路由保持不变 ---
@app.route('/uploads/<filename>')
@login_required
def uploaded_file(filename):
    return send_from_directory(app.config['UPLOAD_FOLDER'], filename)

@app.route('/admin')
@login_required
def admin():
    messages = Message.query.order_by(Message.created_at.desc()).all()
    return render_template('admin.html', messages=messages)

@app.route('/reply/<int:msg_id>', methods=['GET', 'POST'])
@login_required
def reply(msg_id):
    message = Message.query.get_or_404(msg_id)
    if request.method == 'POST':
        reply_text = request.form['reply']
        message.reply = reply_text
        message.replied_at = datetime.now(timezone.utc)
        db.session.commit()
        
        admin_notice = f"💬 Reply to your message:\n\n{reply_text}"
        if message.email:
            threading.Thread(target=send_email, args=("💬 Reply to your message", reply_text), kwargs={"to_email": message.email}, daemon=True).start()
        elif message.telegram_id:
            threading.Thread(target=send_telegram, args=(admin_notice,), kwargs={"chat_id": message.telegram_id}, daemon=True).start()
            
        return redirect(url_for('admin'))
    return render_template('reply.html', message=message)

@app.route('/admin/delete/<int:msg_id>', methods=['POST'])
@login_required
def admin_delete(msg_id):
    message = Message.query.get_or_404(msg_id)
    for attachment in message.attachments:
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], attachment.filename)
        if os.path.exists(filepath):
            os.remove(filepath)
        db.session.delete(attachment)
    db.session.delete(message)
    db.session.commit()
    return '', 204

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        if username == ADMIN_USERNAME and password == ADMIN_PASSWORD:
            login_user(AdminUser(username))
            return redirect(url_for('admin'))
        flash("Invalid credentials", "danger")
    return render_template('login.html')

@app.route('/logout')
@login_required
def logout():
    logout_user()
    return redirect(url_for('login'))

if __name__ == '__main__':
    with app.app_context():
        db.create_all()
    app.run(host='0.0.0.0', port=5000)

