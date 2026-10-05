import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  try {
    const url = Deno.env.get('SUPABASE_URL')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const authorization = request.headers.get('Authorization') || ''
    const accessToken = authorization.replace(/^Bearer\s+/i, '')
    const admin = createClient(url, serviceKey)
    const { data: { user }, error: userError } = await admin.auth.getUser(accessToken)
    if (userError || !user) throw new Error('Требуется вход администратора')
    const { data: profile, error: profileError } = await admin.from('profiles').select('role,active').eq('id', user.id).single()
    if (profileError) throw new Error(`Не удалось проверить права пользователя: ${profileError.message}`)
    if (!profile?.active) throw new Error('Профиль пользователя не активирован')

    const body = await request.json()
    if (!/^\d{6}$/.test(String(body.pin || ''))) throw new Error('PIN должен содержать 6 цифр')

    if (body.action === 'create') {
      if (String(profile.role).trim().toLowerCase() !== 'admin') throw new Error('Только администратор может управлять пользователями. Выйдите и войдите под учётной записью администратора')
      const login = String(body.login || '').trim().toLowerCase()
      const name = String(body.name || '').trim()
      const role = String(body.role || '')
      if (!/^[a-z0-9._-]{3,32}$/.test(login)) throw new Error('Логин: 3–32 латинских символа или цифры')
      if (!name) throw new Error('Введите имя')
      if (!['admin','master','sewer','accountant'].includes(role)) throw new Error('Выберите роль')
      const email = `${login}@users.sewing.local`
      const { data, error } = await admin.auth.admin.createUser({ email, password: String(body.pin), email_confirm: true })
      if (error) throw error
      const { error: profileError } = await admin.from('profiles').insert({ id: data.user.id, display_name: name, role, active: true })
      if (profileError) {
        await admin.auth.admin.deleteUser(data.user.id)
        throw profileError
      }
      return json({ success: true, message: `Пользователь создан. Логин: ${login}` })
    }

    if (body.action === 'reset_pin') {
      const profileId = String(body.profileId || '')
      if (profileId !== user.id && profile.role !== 'admin') throw new Error('Только администратор может менять PIN другого пользователя')
      const { error } = await admin.auth.admin.updateUserById(profileId, { password: String(body.pin) })
      if (error) throw error
      return json({ success: true, message: 'PIN изменён' })
    }
    throw new Error('Неизвестное действие')
  } catch (error) {
    return json({ success: false, message: error instanceof Error ? error.message : 'Ошибка' }, 400)
  }
})

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
}
