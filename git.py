import os
import subprocess
import requests


# 检查当前 Git 配置
def check_git_config():
    subprocess.run(['git', 'config', '--list'], check=True)

check_git_config()


# 设置工作目录
work_dir = "/srv/git"
if not os.path.exists(work_dir):
    os.makedirs(work_dir)
os.chdir(work_dir)


def get_repositories():
    """
    获取用户的 GitHub 仓库，包括私有仓库。
    """
    url = 'https://api.github.com/user/repos?visibility=all&per_page=100'
    headers = {'Authorization': f'token {os.getenv("GITHUB_TOKEN")}'}
    response = requests.get(url, headers=headers)
    response.raise_for_status()
    repos = response.json()
    return [repo['ssh_url'] for repo in repos]


def clone_or_update_repo(repo_url):
    """
    强制以远程仓库为准进行克隆或更新。
    """
    repo_name = repo_url.split('/')[-1].replace('.git', '')

    if os.path.isdir(repo_name):
        print(f"📁 '{repo_name}' 已存在，强制同步远程内容...")
        repo_dir = os.path.join(work_dir, repo_name)
        subprocess.run(['git', 'fetch', '--all'], cwd=repo_dir, check=True)
        subprocess.run(['git', 'reset', '--hard', 'origin/main'], cwd=repo_dir, check=True)
        subprocess.run(['git', 'clean', '-fd'], cwd=repo_dir, check=True)
    else:
        print(f"📥 克隆仓库：{repo_name}")
        subprocess.run(['git', 'clone', repo_url], check=True)


if __name__ == "__main__":
    repos = get_repositories()
    for repo in repos:
        clone_or_update_repo(repo)