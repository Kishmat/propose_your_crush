function happy()
{
    alert("Yeah!!!! same to you! :)");
}

function sad()
{
    alert("Heart Broken :(")
}

function hide_button(element)
{
    let btn = element.firstElementChild;
    btn.style.visibility = 'hidden';
}
function show_button(element)
{
    let btn = element.firstElementChild;
    btn.style.visibility = 'visible';
}