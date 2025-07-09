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
    os.makedirs(work_dir)  # 如果目录不存在，则创建
os.chdir(work_dir)  # 切换到指定目录


def get_repositories():
    """
    获取用户的 GitHub 仓库，包括私有仓库。
    """
    url = 'https://api.github.com/user/repos?type=private&per_page=100'
    headers = {'Authorization': f'token {os.getenv("GITHUB_TOKEN")}'}
    response = requests.get(url, headers=headers)
    response.raise_for_status()  # 如果请求失败，将抛出异常
    repos = response.json()
    return [repo['ssh_url'] for repo in repos]


def clone_or_update_repo(repo_url):
    """
    根据仓库 SSH URL 克隆或更新仓库。
    """
    # 提取仓库名称
    repo_name = repo_url.split('/')[-1].replace('.git', '')

    if os.path.isdir(repo_name):
        print(f"Directory '{repo_name}' already exists. Pulling latest changes...")
        os.chdir(repo_name)
        subprocess.run(['git', 'pull'], check=True)  # 拉取最新代码
        os.chdir('..')
    else:
        print(f"Directory '{repo_name}' does not exist. Cloning repository...")
        subprocess.run(['git', 'clone', repo_url], check=True)  # 克隆仓库


if __name__ == "__main__":
    # 获取仓库列表并克隆或更新
    repos = get_repositories()
    for repo in repos:
        clone_or_update_repo(repo)
