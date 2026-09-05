alias Druzhok.{Repo, User}

# Create admin user if not exists
unless Repo.get_by(User, email: "igor.n.kuz@gmail.com") do
  %User{}
  |> User.admin_changeset(%{
    email: "igor.n.kuz@gmail.com",
    password: "druzhok2026",
    role: "admin"
  })
  |> Repo.insert!()

  IO.puts("Admin user created: igor.n.kuz@gmail.com / druzhok2026")
end
