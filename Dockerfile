FROM mcr.microsoft.com/powershell:latest
WORKDIR /app
COPY Jeremy-Shockey.ps1 /app/Jeremy-Shockey.ps1
CMD ["pwsh","-NoLogo","-File","/app/Jeremy-Shockey.ps1"]
