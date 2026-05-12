import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import { login } from '../lib/api'

export default function LoginPassword() {
  const navigate = useNavigate()
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()

    setLoading(true)
    try {
      await login(username.trim(), password)
      navigate('/', { replace: true })
    } catch (err: unknown) {
      const errorMessage = err instanceof Error ? err.message : '登录失败'
      setError(errorMessage)
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-light-sidebar px-4">
      <div className="w-full max-w-md rounded-xl border border-light-border bg-light-card p-6 shadow-sm">
        <div className="mb-6 flex flex-col items-center gap-2">
          <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-accent-blue text-lg font-semibold text-white">S</div>
          <h1 className="text-lg font-semibold text-light-text">MedClaw Shared</h1>
          <p className="text-sm text-light-text-secondary">共享 OpenClaw 轻量工作台</p>
        </div>

        {error && (
          <div className="mb-4 rounded-lg bg-accent-red/10 p-3 text-sm text-accent-red">
            {error}
          </div>
        )}

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label htmlFor="username" className="mb-2 block text-sm font-medium text-light-text">
              用户名
            </label>
            <input
              id="username"
              type="text"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              className="w-full rounded-lg border border-light-border bg-light-bg px-4 py-2.5 text-light-text placeholder-light-text-secondary focus:border-accent-blue focus:outline-none focus:ring-1 focus:ring-accent-blue disabled:opacity-50"
              placeholder="请输入用户名"
              disabled={loading}
              required
            />
          </div>

          <div>
            <label htmlFor="password" className="mb-2 block text-sm font-medium text-light-text">
              密码
            </label>
            <input
              id="password"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="w-full rounded-lg border border-light-border bg-light-bg px-4 py-2.5 text-light-text placeholder-light-text-secondary focus:border-accent-blue focus:outline-none focus:ring-1 focus:ring-accent-blue disabled:opacity-50"
              placeholder="请输入密码"
              disabled={loading}
              required
            />
          </div>

          <button
            type="submit"
            disabled={loading || !username || !password}
            className="flex w-full items-center justify-center gap-2 rounded-lg bg-accent-blue px-4 py-2.5 text-sm font-medium text-white hover:bg-accent-blue/90 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {loading ? (
              <>
                <Loader2 className="h-4 w-4 animate-spin" />
                <span>登录中...</span>
              </>
            ) : (
              <span>登录</span>
            )}
          </button>
        </form>

        <div className="mt-4 space-y-2 text-center text-xs text-light-text-secondary">
          <p>使用您的账号密码登录共享模式</p>
          <Link to="/login" className="text-accent-blue hover:underline">
            返回扫码登录
          </Link>
        </div>
      </div>
    </div>
  )
}
